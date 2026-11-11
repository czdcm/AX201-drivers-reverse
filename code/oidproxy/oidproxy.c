// oidproxy.c - minimal NDIS protocol driver that proxies OID requests from user mode
// to the bound miniport. Experiment aid only: no filtering, no data path.

#include <ntddk.h>
#include <stdarg.h>
#include <ndis.h>

#define OIDPROXY_POOL_TAG 'dpiO'

#define OIDPROXY_DEVICE_NAME   L"\\Device\\OidProxy"
#define OIDPROXY_SYMLINK_NAME  L"\\DosDevices\\OidProxy"

#define IOCTL_OIDPROXY_SEND \
    CTL_CODE(0x00000022, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _OIDPROXY_REQUEST {
    ULONG Oid;
    ULONG Method;      // 0 = query, 1 = set, 2 = method
    ULONG InLength;
    ULONG OutLength;
    ULONG Status;      // NDIS_STATUS observed
    UCHAR Data[1];
} OIDPROXY_REQUEST, *POIDPROXY_REQUEST;

static NDIS_HANDLE g_ProtocolHandle = NULL;
static NDIS_HANDLE g_BindingHandle = NULL;
static PDEVICE_OBJECT g_DeviceObject = NULL;
static volatile LONG g_Bound = 0;

static KEVENT g_OidEvent;
static NDIS_STATUS g_LastOidStatus = NDIS_STATUS_FAILURE;

static VOID Log(PCSTR fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vDbgPrintExWithPrefix("OIDPROXY: ", DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL, fmt, ap);
    va_end(ap);
}

// ---------------------------------------------------------------- NDIS glue

static VOID ProtocolUninstall(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);
    Log("Uninstall\n");
}

static NDIS_STATUS ProtocolBindAdapterEx(
    NDIS_HANDLE ProtocolDriverContext,
    NDIS_HANDLE BindContext,
    PNDIS_BIND_PARAMETERS BindParameters)
{
    NDIS_STATUS status;
    NDIS_OPEN_PARAMETERS params;
    NDIS_STRING adapterName;

    UNREFERENCED_PARAMETER(ProtocolDriverContext);
    UNREFERENCED_PARAMETER(BindContext);

    Log("BindAdapterEx\n");

    if (g_BindingHandle != NULL) {
        Log("already bound\n");
        return NDIS_STATUS_FAILURE;
    }

    adapterName = *BindParameters->AdapterName;

    NdisZeroMemory(&params, sizeof(params));
    params.Header.Type = NDIS_OBJECT_TYPE_OPEN_PARAMETERS;
    params.Header.Revision = NDIS_OPEN_PARAMETERS_REVISION_1;
    params.Header.Size = NDIS_SIZEOF_OPEN_PARAMETERS_REVISION_1;
    params.AdapterName = &adapterName;
    params.MediumArray = NULL;
    params.MediumArraySize = 0;
    params.SelectedMediumIndex = NULL;
    params.FrameTypeArray = NULL;
    params.FrameTypeArraySize = 0;

    status = NdisOpenAdapterEx(g_ProtocolHandle, NULL, &params, NULL, &g_BindingHandle);
    if (status == NDIS_STATUS_SUCCESS) {
        InterlockedExchange(&g_Bound, 1);
        Log("bound ok\n");
    } else {
        g_BindingHandle = NULL;
        Log("NdisOpenAdapterEx failed 0x%08X\n", status);
    }
    return status;
}

static NDIS_STATUS ProtocolUnbindAdapterEx(
    NDIS_HANDLE UnbindContext,
    NDIS_HANDLE ProtocolBindingContext)
{
    UNREFERENCED_PARAMETER(UnbindContext);
    UNREFERENCED_PARAMETER(ProtocolBindingContext);

    Log("UnbindAdapterEx\n");
    InterlockedExchange(&g_Bound, 0);
    if (g_BindingHandle != NULL) {
        NdisCloseAdapterEx(g_BindingHandle);
        g_BindingHandle = NULL;
    }
    return NDIS_STATUS_SUCCESS;
}

static VOID ProtocolOidRequestComplete(
    NDIS_HANDLE ProtocolBindingContext,
    PNDIS_OID_REQUEST OidRequest,
    NDIS_STATUS Status)
{
    UNREFERENCED_PARAMETER(ProtocolBindingContext);
    UNREFERENCED_PARAMETER(OidRequest);

    g_LastOidStatus = Status;
    KeSetEvent(&g_OidEvent, IO_NO_INCREMENT, FALSE);
}

static VOID ProtocolReceiveNetBufferLists(
    NDIS_HANDLE ProtocolBindingContext,
    PNET_BUFFER_LIST NetBufferLists,
    ULONG NumberOfNetBufferLists,
    ULONG ReceiveFlags)
{
    UNREFERENCED_PARAMETER(ProtocolBindingContext);
    UNREFERENCED_PARAMETER(NumberOfNetBufferLists);

    NdisReturnNetBufferLists(g_BindingHandle, NetBufferLists,
        (ReceiveFlags & NDIS_RECEIVE_FLAGS_RESOURCES) ? 0 : 0);
}

// ---------------------------------------------------------------- OID path

static NTSTATUS SendOid(POIDPROXY_REQUEST req)
{
    NDIS_OID_REQUEST r;
    NDIS_STATUS status;
    LARGE_INTEGER timeout;

    if (g_BindingHandle == NULL) {
        return STATUS_DEVICE_NOT_READY;
    }

    NdisZeroMemory(&r, sizeof(r));
    r.Header.Type = NDIS_OBJECT_TYPE_OID_REQUEST;
    r.Header.Revision = NDIS_OID_REQUEST_REVISION_1;
    r.Header.Size = NDIS_SIZEOF_OID_REQUEST_REVISION_1;
    r.Timeout = 2;

    switch (req->Method) {
    case 0:
        r.RequestType = NdisRequestQueryInformation;
        r.DATA.QUERY_INFORMATION.Oid = req->Oid;
        r.DATA.QUERY_INFORMATION.InformationBuffer = req->Data;
        r.DATA.QUERY_INFORMATION.InformationBufferLength = req->OutLength;
        break;
    case 1:
        r.RequestType = NdisRequestSetInformation;
        r.DATA.SET_INFORMATION.Oid = req->Oid;
        r.DATA.SET_INFORMATION.InformationBuffer = req->Data;
        r.DATA.SET_INFORMATION.InformationBufferLength = req->InLength;
        break;
    case 2:
        r.RequestType = NdisRequestMethod;
        r.DATA.METHOD_INFORMATION.Oid = req->Oid;
        r.DATA.METHOD_INFORMATION.InformationBuffer = req->Data;
        r.DATA.METHOD_INFORMATION.InputBufferLength = req->InLength;
        r.DATA.METHOD_INFORMATION.OutputBufferLength = req->OutLength;
        r.DATA.METHOD_INFORMATION.MethodId = 0;
        break;
    default:
        return STATUS_INVALID_PARAMETER;
    }

    KeResetEvent(&g_OidEvent);
    g_LastOidStatus = NDIS_STATUS_FAILURE;

    status = NdisOidRequest(g_BindingHandle, &r);
    if (status == NDIS_STATUS_PENDING) {
        timeout.QuadPart = -3LL * 1000 * 1000 * 10;
        if (KeWaitForSingleObject(&g_OidEvent, Executive, KernelMode, FALSE, &timeout) != STATUS_SUCCESS) {
            return STATUS_IO_TIMEOUT;
        }
        status = g_LastOidStatus;
    }

    req->Status = status;
    if (r.RequestType == NdisRequestMethod) {
        req->OutLength = r.DATA.METHOD_INFORMATION.BytesWritten;
    } else if (r.RequestType == NdisRequestQueryInformation) {
        req->OutLength = r.DATA.QUERY_INFORMATION.BytesWritten;
    } else {
        req->OutLength = r.DATA.SET_INFORMATION.BytesRead;
    }

    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------- IRP

static NTSTATUS DispatchCreateClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS DispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status = STATUS_SUCCESS;
    ULONG inLen = sp->Parameters.DeviceIoControl.InputBufferLength;
    ULONG outLen = sp->Parameters.DeviceIoControl.OutputBufferLength;
    PVOID buf = Irp->AssociatedIrp.SystemBuffer;

    UNREFERENCED_PARAMETER(DeviceObject);

    if (sp->Parameters.DeviceIoControl.IoControlCode != IOCTL_OIDPROXY_SEND) {
        status = STATUS_INVALID_DEVICE_REQUEST;
        goto done;
    }
    if (buf == NULL || inLen < RTL_SIZEOF_THROUGH_FIELD(OIDPROXY_REQUEST, Status) || outLen < inLen) {
        status = STATUS_BUFFER_TOO_SMALL;
        goto done;
    }

    status = SendOid((POIDPROXY_REQUEST)buf);
    if (NT_SUCCESS(status)) {
        Irp->IoStatus.Information = inLen;
    }

done:
    Irp->IoStatus.Status = status;
    if (!NT_SUCCESS(status)) {
        Irp->IoStatus.Information = 0;
    }
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

static VOID DriverUnload(PDRIVER_OBJECT DriverObject)
{
    UNICODE_STRING sym;
    Log("unload\n");

    if (g_ProtocolHandle != NULL) {
        NdisDeregisterProtocolDriver(g_ProtocolHandle);
        g_ProtocolHandle = NULL;
    }
    RtlInitUnicodeString(&sym, OIDPROXY_SYMLINK_NAME);
    IoDeleteSymbolicLink(&sym);
    if (g_DeviceObject != NULL) {
        IoDeleteDevice(g_DeviceObject);
        g_DeviceObject = NULL;
    }
    UNREFERENCED_PARAMETER(DriverObject);
}

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    NTSTATUS status;
    UNICODE_STRING devName, symName;
    PDEVICE_OBJECT devObj = NULL;
    NDIS_PROTOCOL_DRIVER_CHARACTERISTICS chars;
    NDIS_STRING protoName;

    UNREFERENCED_PARAMETER(RegistryPath);

    Log("DriverEntry\n");
    KeInitializeEvent(&g_OidEvent, NotificationEvent, FALSE);

    RtlInitUnicodeString(&devName, OIDPROXY_DEVICE_NAME);
    status = IoCreateDevice(DriverObject, 0, &devName, FILE_DEVICE_UNKNOWN,
        FILE_DEVICE_SECURE_OPEN, FALSE, &devObj);
    if (!NT_SUCCESS(status)) {
        Log("IoCreateDevice failed 0x%08X\n", status);
        return status;
    }
    g_DeviceObject = devObj;

    RtlInitUnicodeString(&symName, OIDPROXY_SYMLINK_NAME);
    status = IoCreateSymbolicLink(&symName, &devName);
    if (!NT_SUCCESS(status)) {
        Log("IoCreateSymbolicLink failed 0x%08X\n", status);
        IoDeleteDevice(devObj);
        g_DeviceObject = NULL;
        return status;
    }

    DriverObject->MajorFunction[IRP_MJ_CREATE] = DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchDeviceControl;
    DriverObject->DriverUnload = DriverUnload;

    NdisZeroMemory(&chars, sizeof(chars));
    chars.Header.Type = NDIS_OBJECT_TYPE_PROTOCOL_DRIVER_CHARACTERISTICS;
    chars.Header.Revision = NDIS_PROTOCOL_DRIVER_CHARACTERISTICS_REVISION_2;
    chars.Header.Size = NDIS_SIZEOF_PROTOCOL_DRIVER_CHARACTERISTICS_REVISION_2;
    chars.MajorNdisVersion = 6;
    chars.MinorNdisVersion = 80;
    chars.MajorDriverVersion = 1;
    chars.MinorDriverVersion = 0;
    chars.Flags = 0;
    NdisInitUnicodeString(&protoName, L"OidProxy");
    chars.Name = protoName;
    chars.SetOptionsHandler = NULL;
    chars.BindAdapterHandlerEx = ProtocolBindAdapterEx;
    chars.UnbindAdapterHandlerEx = ProtocolUnbindAdapterEx;
    chars.OpenAdapterCompleteHandlerEx = NULL;
    chars.CloseAdapterCompleteHandlerEx = NULL;
    chars.NetPnPEventHandler = NULL;
    chars.UninstallHandler = ProtocolUninstall;
    chars.OidRequestCompleteHandler = ProtocolOidRequestComplete;
    chars.StatusHandlerEx = NULL;
    chars.ReceiveNetBufferListsHandler = ProtocolReceiveNetBufferLists;
    chars.SendNetBufferListsCompleteHandler = NULL;
    chars.DirectOidRequestCompleteHandler = NULL;

    status = NdisRegisterProtocolDriver(NULL, &chars, &g_ProtocolHandle);
    if (status != NDIS_STATUS_SUCCESS) {
        Log("NdisRegisterProtocolDriver failed 0x%08X\n", status);
        g_ProtocolHandle = NULL;
    } else {
        Log("protocol registered\n");
    }

    return STATUS_SUCCESS;
}
