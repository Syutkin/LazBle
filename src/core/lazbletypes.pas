unit LazBleTypes;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SimpleDelphiBLE;

type
  TBleOperationId = type QWord;
  TBleSubscriptionId = type QWord;

  { Reconnect delays use milliseconds. MaximumAttempts limits retries;
    the controller validates the delay range when options are assigned. }
  TLazBleReconnectOptions = record
    InitialDelayMs: Cardinal;
    MaximumDelayMs: Cardinal;
    MaximumAttempts: Cardinal;
    class function Create(const AInitialDelayMs, AMaximumDelayMs,
      AMaximumAttempts: Cardinal): TLazBleReconnectOptions; static;
  end;

  { A scan result. DeviceId is the backend identifier used to create a client. }
  TBleDeviceInfo = record
    DeviceId: string;
    DeviceName: string;
    Rssi: SmallInt;
  end;
  TBleDeviceInfos = array of TBleDeviceInfo;
  TLazBleScanResultEvent = procedure(Sender: TObject; const ADeviceId,
    ADeviceName: string; const ARssi: SmallInt) of object;

  TBleAvailability = (
    lbaUnknown,
    lbaChecking,
    lbaAvailable,
    lbaUnavailable
  );
  TBleAvailabilityEvent = procedure(Sender: TObject;
    const AAvailability: TBleAvailability) of object;

  { Static information about the compiled LazBle package. None of these
    fields describes the selected backend or a loaded native library. }
  TLazBleInfo = record
    Name: string;
    { Version of the compiled LazBle source, independent of native BLE. }
    Version: string;
    { Human-readable package purpose; not a runtime capability report. }
    About: string;
  end;

  { A read-only snapshot. NativeVersion and AdapterId are filled by an
    availability check. Empty NativeVersion means no native version was
    obtained. Reading this record never loads native libraries or starts
    an operation. }
  TLazBleDiagnosticInfo = record
    { Name supplied by ILazBleBackend, or 'unknown' if it returns empty. }
    BackendName: string;
    { Version reported by the loaded native backend after an availability
      check. Empty means not obtained, including after a failed check. }
    NativeVersion: string;
    { Selected adapter identifier, empty until reported by the backend. }
    AdapterId: string;
    { lbaUnknown before a check, lbaChecking until completion, and
      lbaUnavailable once shutdown starts. }
    Availability: TBleAvailability;
    { Error from the most recent availability check, if it failed. }
    AvailabilityErrorMessage: string;
  end;

const
  InvalidBleOperationId: TBleOperationId = 0;
  InvalidBleSubscriptionId: TBleSubscriptionId = 0;
  // Negative codes are reserved for lazble; SimpleBLE error ordinals are nonnegative.
  LazBleErrorInvalidState = -1000;
  LazBleErrorGattNotFound = -1001;
  LazBleErrorGattPropertyNotSupported = -1002;
  LazBleErrorNoAdapter = -1003;
  LazBleErrorAdapterNotFound = -1004;
  LazBleErrorAdapterAlreadyActive = -1005;
  LazBleErrorBluetoothDisabled = -1006;
  LazBleErrorDeviceNotFound = -1007;
  LazBleErrorDeviceNotKnown = -1008;
  LazBleErrorDeviceDisconnected = -1009;
  LazBleErrorInvalidGattUuid = -1010;
  LazBleErrorSubscriptionNotKnown = -1011;
  LazBleErrorInvalidNativeData = -1012;
  LazBleErrorNativeDataTooLarge = -1013;
  LazBleErrorCommandNotImplemented = -1014;
  LazBleErrorBackendUnavailable = -1015;
  LazBleErrorInvalidProfileData = -1017;

type
  { Request waits for a GATT write response; Command writes without one. }
  TLazBleWriteMode = (
    lbwmRequest,
    lbwmCommand
  );

  { Aliases of upstream records. Snapshots and their nested arrays are read-only;
    consumers needing mutable data must explicitly copy the arrays they change. }
  TLazBleGattDescriptor = UnicodeString;
  TLazBleGattDescriptors = specialize TArray<UnicodeString>;
  TLazBleGattCharacteristic = TBleCharacteristic;
  TLazBleGattCharacteristics = specialize TArray<TBleCharacteristic>;
  TLazBleGattService = TBleService;
  TLazBleGattServices = specialize TArray<TBleService>;

  TLazBleBackendCommandKind = (
    lbckStartScan,
    lbckStopScan,
    lbckConnect,
    lbckDisconnect,
    lbckDiscoverServices,
    lbckRead,
    lbckWrite,
    lbckSubscribe,
    lbckUnsubscribe,
    lbckCheckAvailability
  );

  TLazBleBackendCommand = record
    Kind: TLazBleBackendCommandKind;
    Generation: QWord;
    AdapterId: string;
    DeviceId: string;
    ServiceUuid: string;
    CharacteristicUuid: string;
    TimeoutMs: Cardinal;
    WriteMode: TLazBleWriteMode;
    Value: TBytes;
    SubscriptionId: TBleSubscriptionId;
  end;

  TLazBleBackendEventKind = (
    lbekScanStarted,
    lbekScanResult,
    lbekScanStopped,
    lbekConnected,
    lbekDisconnected,
    lbekServicesDiscovered,
    lbekReadResult,
    lbekWriteCompleted,
    lbekSubscribed,
    lbekNotification,
    lbekUnsubscribed,
    lbekAvailabilityResult,
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled,
    lbekShutdownCompleted
  );

  TLazBleBackendEvent = record
    Kind: TLazBleBackendEventKind;
    OperationId: TBleOperationId;
    SubscriptionId: TBleSubscriptionId;
    Generation: QWord;
    BackendName: string;
    BackendVersion: string;
    AdapterId: string;
    DeviceId: string;
    DeviceName: string;
    ServiceUuid: string;
    CharacteristicUuid: string;
    Rssi: SmallInt;
    Available: Boolean;
    Value: TBytes;
    { Explicit flag for ShutdownCompleted: native error 0/empty text is valid. }
    ShutdownFailed: Boolean;
    ErrorCode: Integer;
    ErrorMessage: string;
    Services: TLazBleGattServices;
  end;

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;
{ Main-thread contract shared by core, profiles, and custom backends. }
procedure LazBleRequireMainThread;

implementation

class function TLazBleReconnectOptions.Create(const AInitialDelayMs,
  AMaximumDelayMs, AMaximumAttempts: Cardinal): TLazBleReconnectOptions;
begin
  Result.InitialDelayMs := AInitialDelayMs;
  Result.MaximumDelayMs := AMaximumDelayMs;
  Result.MaximumAttempts := AMaximumAttempts;
end;

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;
begin
  Result := AEvent.Kind in [
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled,
    lbekShutdownCompleted
  ];
end;

procedure LazBleRequireMainThread;
begin
  if GetCurrentThreadID <> MainThreadID then
    raise EInvalidOperation.Create('LazBle API requires the main thread');
end;

end.
