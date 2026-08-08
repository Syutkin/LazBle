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
  end;

function LazBleBackendEventIsTerminal(
  const AEvent: TLazBleBackendEvent): Boolean;

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

end.
