unit LazBleTypes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TBleOperationId = type QWord;
  TBleSubscriptionId = type QWord;

const
  InvalidBleOperationId: TBleOperationId = 0;
  InvalidBleSubscriptionId: TBleSubscriptionId = 0;

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
    lbckUnsubscribe
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
    AdapterId: string;
    DeviceId: string;
    DeviceName: string;
    ServiceUuid: string;
    CharacteristicUuid: string;
    Rssi: SmallInt;
    Value: TBytes;
    ErrorCode: Integer;
    ErrorMessage: string;
    Services: TLazBleGattServices;
  end;

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;
function LazBleCopyGattServices(
  const AServices: TLazBleGattServices): TLazBleGattServices;

implementation

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
