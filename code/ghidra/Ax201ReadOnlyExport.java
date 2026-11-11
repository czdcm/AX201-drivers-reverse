// Read-only evidence export for an already analyzed local program.
// Does not write program bytes, labels, types, or project state; use -readOnly -noanalysis.
// @category AX201.Research
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;

public class Ax201ReadOnlyExport extends GhidraScript {
    private final Gson gson = new GsonBuilder().setPrettyPrinting().create();
    private final LinkedHashMap<String,Function> selected = new LinkedHashMap<>();
    private int limit = 48;
    private void add(Function f) {
        if (f != null && !f.isExternal() && selected.size() < limit)
            selected.putIfAbsent(f.getEntryPoint().toString(), f);
    }
    private JsonObject identity(Function f) {
        JsonObject o = new JsonObject();
        o.addProperty("address", f.getEntryPoint().toString());
        o.addProperty("name", f.getName(true));
        o.addProperty("external", f.isExternal());
        o.addProperty("thunk", f.isThunk());
        return o;
    }
    private JsonArray functions(Collection<Function> fs) {
        JsonArray a = new JsonArray();
        for (Function f : fs) a.add(identity(f));
        return a;
    }
    @Override public void run() throws Exception {
        if (currentProgram == null) throw new IllegalStateException("No program");
        String[] args = getScriptArgs();
        if (args.length != 1) throw new IllegalArgumentException("One JSON configuration path required");
        JsonObject cfg;
        try (Reader r = Files.newBufferedReader(Path.of(args[0]), StandardCharsets.UTF_8)) {
            cfg = JsonParser.parseReader(r).getAsJsonObject();
        }
        Path out = Path.of(cfg.get("output").getAsString());
        Files.createDirectories(out);
        if (cfg.has("maxFunctions")) limit = cfg.get("maxFunctions").getAsInt();
        for (JsonElement e : cfg.getAsJsonArray("addresses")) {
            Address a = currentProgram.getAddressFactory().getAddress(e.getAsString());
            if (a != null) add(currentProgram.getFunctionManager().getFunctionContaining(a));
        }
        JsonArray strings = new JsonArray();
        DataIterator it = currentProgram.getListing().getDefinedData(true);
        while (it.hasNext()) {
            monitor.checkCancelled();
            Data d = it.next();
            if (!d.hasStringValue()) continue;
            Object value = d.getValue();
            if (value == null) continue;
            String s = value.toString();
            boolean match = false;
            for (JsonElement needle : cfg.getAsJsonArray("stringContains")) {
                if (s.toLowerCase(Locale.ROOT).contains(needle.getAsString().toLowerCase(Locale.ROOT))) { match=true; break; }
            }
            if (!match) continue;
            JsonObject record = new JsonObject();
            record.addProperty("address", d.getAddress().toString());
            record.addProperty("text", s);
            JsonArray refs = new JsonArray();
            ReferenceIterator ri = currentProgram.getReferenceManager().getReferencesTo(d.getAddress());
            while (ri.hasNext()) {
                Reference ref = ri.next();
                JsonObject x = new JsonObject();
                x.addProperty("from", ref.getFromAddress().toString());
                x.addProperty("type", ref.getReferenceType().toString());
                Function f = currentProgram.getFunctionManager().getFunctionContaining(ref.getFromAddress());
                if (f != null) { x.add("function", identity(f)); add(f); }
                refs.add(x);
            }
            record.add("references", refs);
            strings.add(record);
            if (strings.size() >= 160) break;
        }
        JsonArray probes = new JsonArray();
        if (cfg.has("dataProbes")) for (JsonElement item : cfg.getAsJsonArray("dataProbes")) {
            JsonObject spec = item.getAsJsonObject();
            Address start = currentProgram.getAddressFactory().getAddress(spec.get("address").getAsString());
            int words = Math.min(spec.get("qwords").getAsInt(), 96);
            JsonObject probe = new JsonObject();
            probe.addProperty("start", start.toString());
            JsonArray rows = new JsonArray();
            for (int k=0; k<words; k++) {
                Address at = start.add(k*8L);
                JsonObject row = new JsonObject();
                row.addProperty("address",at.toString());
                try {
                    long bits = currentProgram.getMemory().getLong(at);
                    row.addProperty("hex64",String.format("%016x",bits));
                    row.addProperty("low32",String.format("%08x",(int)bits));
                    row.addProperty("high32",String.format("%08x",(int)(bits>>>32)));
                    Address ptr=currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(bits);
                    if(currentProgram.getMemory().contains(ptr)) {
                        row.addProperty("mappedPointer",ptr.toString());
                        Function pf=currentProgram.getFunctionManager().getFunctionAt(ptr);
                        if(pf!=null) {row.add("targetFunction",identity(pf)); if(spec.has("followFunctions")&&spec.get("followFunctions").getAsBoolean()) add(pf);}
                        Data pd=currentProgram.getListing().getDataAt(ptr);
                        if(pd!=null && pd.hasStringValue()) row.addProperty("targetString",String.valueOf(pd.getValue()));
                    }
                } catch(Exception ex) {row.addProperty("error",ex.toString());}
                JsonArray xr=new JsonArray();
                ReferenceIterator refs=currentProgram.getReferenceManager().getReferencesTo(at);
                while(refs.hasNext() && xr.size()<100) {
                    Reference r=refs.next(); JsonObject x=new JsonObject(); x.addProperty("from",r.getFromAddress().toString());x.addProperty("type",r.getReferenceType().toString());
                    Function rf=currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
                    if(rf!=null){x.add("function",identity(rf));add(rf);}xr.add(x);
                }
                row.add("references",xr);rows.add(row);
            }
            probe.add("rows",rows);probes.add(probe);
        }
        if (cfg.has("includeCallers") && cfg.get("includeCallers").getAsBoolean()) {
            for (Function f : new ArrayList<>(selected.values())) {
                for (Function caller : f.getCallingFunctions(monitor)) add(caller);
            }
        }
        JsonObject result = new JsonObject();
        result.addProperty("program", currentProgram.getName());
        result.addProperty("imageBase", currentProgram.getImageBase().toString());
        result.addProperty("executableSHA256", currentProgram.getExecutableSHA256());
        result.addProperty("readOnlyExport", true);
        result.addProperty("limitations", "Decompiler output and inferred types/names require manual validation; references can miss indirect pointers; bounded export, not complete reverse engineering.");
        result.add("strings", strings);
        result.add("dataProbes", probes);
        JsonArray exported = new JsonArray();
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IOException("Decompiler open failed");
            long deadline = System.nanoTime() + 240_000_000_000L;
            for (Function f : selected.values()) {
                monitor.checkCancelled();
                if (System.nanoTime() > deadline) { result.addProperty("timeBudgetReached", true); break; }
                JsonObject info = identity(f);
                info.addProperty("signature", f.getPrototypeString(true, true));
                info.addProperty("bodyBytes", f.getBody().getNumAddresses());
                info.add("callers", functions(f.getCallingFunctions(monitor)));
                info.add("callees", functions(f.getCalledFunctions(monitor)));
                JsonArray refs = new JsonArray();
                ReferenceIterator ri = currentProgram.getReferenceManager().getReferencesTo(f.getEntryPoint());
                while (ri.hasNext() && refs.size()<160) {
                    Reference r=ri.next(); JsonObject x=new JsonObject();
                    x.addProperty("from",r.getFromAddress().toString()); x.addProperty("type",r.getReferenceType().toString()); refs.add(x);
                }
                info.add("entryReferences", refs);
                DecompileResults dr = decompiler.decompileFunction(f, 25, monitor);
                info.addProperty("decompileCompleted", dr.decompileCompleted());
                info.addProperty("decompileMessage", dr.getErrorMessage());
                if (dr.decompileCompleted() && dr.getDecompiledFunction()!=null) {
                    Path c = out.resolve(f.getEntryPoint().toString()+".c");
                    Files.writeString(c, "/* Ghidra pseudocode; not original source; static VA " + f.getEntryPoint()+" */\n"+dr.getDecompiledFunction().getC(), StandardCharsets.UTF_8);
                    info.addProperty("pseudocode", c.getFileName().toString());
                }
                StringBuilder asm = new StringBuilder();
                InstructionIterator ins = currentProgram.getListing().getInstructions(f.getBody(), true);
                int count=0;
                while(ins.hasNext() && count++<1200) { Instruction i=ins.next(); asm.append(i.getAddress()).append("  ").append(i).append('\n'); }
                Files.writeString(out.resolve(f.getEntryPoint().toString()+".asm.txt"), asm.toString(), StandardCharsets.UTF_8);
                exported.add(info);
            }
        } finally { decompiler.dispose(); }
        result.add("functions", exported);
        result.addProperty("exportedFunctions", exported.size());
        Files.writeString(out.resolve("evidence.json"), gson.toJson(result), StandardCharsets.UTF_8);
        println("AX201_EXPORT_OK program="+currentProgram.getName()+" functions="+exported.size()+" output="+out);
    }
}
