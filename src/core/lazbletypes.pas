unit LazBleTypes;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  TBleOperationId = type QWord;
  TBleSubscriptionId = type QWord;

  TLazBleReconnectOptions = record
    InitialDelayMs: Cardinal;
    MaximumDelayMs: Cardinal;
    MaximumAttempts: Cardinal;
    class function Create(const AInitialDelayMs, AMaximumDelayMs,
      AMaximumAttempts: Cardinal): TLazBleReconnectOptions; static;
  end;

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

  TLazBleAbout = record
    Name: string;
    { Version of the compiled LazBle source, independent of native BLE. }
    Version: string;
    Description: string;
  end;

  { Information returned by an availability check. Version is the version
    reported by the loaded native backend, not the LazBle package version.
    Empty fields mean the value could not yet be obtained. }
  TLazBleBackendInfo = record
    Name: string;
    Version: string;
    AdapterId: string;
    { Loader warning for a native major version newer than the tested range.
      Empty when no warning was raised or no library was loaded. }
    LoadWarning: string;
  end;

  { A read-only snapshot. Static versions are available before any BLE work;
    NativeVersion and AdapterId are filled by an availability check. Empty
    NativeVersion means no native version was obtained. Reading this record
    never loads native libraries or starts an operation. }
  TLazBleDiagnosticInfo = record
    LazBleVersion: string;
    { Version of the compiled SimpleBlePascal package. }
    BindingVersion: string;
    { Minimum native SimpleCBLE version accepted by its loader. }
    MinimumNativeVersion: string;
    { Name supplied by ILazBleBackend, or 'unknown' if it returns empty. }
    BackendName: string;
    { Version reported by the loaded native backend after availability check. }
    NativeVersion: string;
    AdapterId: string;
    Availability: TBleAvailability;
    { Error from the most recent availability check, if it failed. }
    ErrorMessage: string;
    { Native loader warning from the most recent availability check. }
    WarningMessage: string;
  end;
  TLazBleAvailabilityResultEvent = procedure(Sender: TObject;
    const AAvailability: TBleAvailability;
    const ABackendInfo: TLazBleBackendInfo) of object;

const
  { Source version of the LazBle package, also available without a facade. }
  LazBleVersion = '1.2.0';
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
  LazBleErrorOperationTimedOut = -1016;
  LazBleErrorInvalidProfileData = -1017;

type
  TLazBleWriteMode = (
    lbwmRequest,
    lbwmCommand
  );

  TLazBleGattCharacteristicProperty = (
    lbgcpRead,
    lbgcpWriteRequest,
    lbgcpWriteCommand,
    lbgcpNotify,
    lbgcpIndicate
  );
  TLazBleGattCharacteristicProperties = set of
    TLazBleGattCharacteristicProperty;

  TLazBleGattDescriptor = record
    Uuid: string;
  end;
  TLazBleGattDescriptors = array of TLazBleGattDescriptor;

  TLazBleGattCharacteristic = record
    Uuid: string;
    Properties: TLazBleGattCharacteristicProperties;
    Descriptors: TLazBleGattDescriptors;
  end;
  TLazBleGattCharacteristics = array of TLazBleGattCharacteristic;

  TLazBleGattService = record
    Uuid: string;
    Data: TBytes;
    Characteristics: TLazBleGattCharacteristics;
  end;
  TLazBleGattServices = array of TLazBleGattService;

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
    BackendWarning: string;
    AdapterId: string;
    DeviceId: string;
    DeviceName: string;
    ServiceUuid: string;
    CharacteristicUuid: string;
    Rssi: SmallInt;
    Available: Boolean;
    Value: TBytes;
    ErrorCode: Integer;
    ErrorMessage: string;
    Services: TLazBleGattServices;
  end;

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;
{ Returns static package information without constructing a backend or
  loading a native library. Example: Info := LazBleGetAbout; }
function LazBleGetAbout: TLazBleAbout;
function LazBleCopyGattServices(
  const AServices: TLazBleGattServices): TLazBleGattServices;

implementation

function LazBleGetAbout: TLazBleAbout;
begin
  Result.Name := 'LazBle';
  Result.Version := LazBleVersion;
  Result.Description := 'Asynchronous BLE and GATT client library for Free Pascal';
end;

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

function LazBleCopyGattServices(
  const AServices: TLazBleGattServices): TLazBleGattServices;
var
  CharacteristicIndex: Integer;
  ServiceIndex: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AServices));
  for ServiceIndex := 0 to High(AServices) do
  begin
    Result[ServiceIndex].Uuid := AServices[ServiceIndex].Uuid;
    Result[ServiceIndex].Data := Copy(AServices[ServiceIndex].Data);
    SetLength(Result[ServiceIndex].Characteristics,
      Length(AServices[ServiceIndex].Characteristics));
    for CharacteristicIndex := 0 to
      High(AServices[ServiceIndex].Characteristics) do
    begin
      Result[ServiceIndex].Characteristics[CharacteristicIndex].Uuid :=
        AServices[ServiceIndex].Characteristics[CharacteristicIndex].Uuid;
      Result[ServiceIndex].Characteristics[CharacteristicIndex].Properties :=
        AServices[ServiceIndex].Characteristics[CharacteristicIndex].Properties;
      Result[ServiceIndex].Characteristics[CharacteristicIndex].Descriptors :=
        Copy(AServices[ServiceIndex].Characteristics[
          CharacteristicIndex].Descriptors);
    end;
  end;
end;

end.
