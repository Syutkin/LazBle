unit LazBleClientInternal;

{$mode objfpc}{$H+}

interface

uses
  LazBleOperation,
  LazBleGattSession;

type
  TLazBleSessionOperationKind = (
    lbsokConnect,
    lbsokDisconnect
  );

  TBleSessionOperation = class(TBleOperation)
  private
    FKind: TLazBleSessionOperationKind;
    FSession: TBleGattSession;
  public
    constructor Create(const ASession: TBleGattSession;
      const AKind: TLazBleSessionOperationKind;
      const AOnCancel: TLazBleOperationCancelEvent);
    property Kind: TLazBleSessionOperationKind read FKind;
    property Session: TBleGattSession read FSession;
  end;

  TLazBleConnectSessionEvent = function(const ADeviceId: string):
    IBleOperation of object;
  TLazBleDisconnectSessionEvent = function(
    const ASession: TBleGattSession): IBleOperation of object;

implementation

constructor TBleSessionOperation.Create(const ASession: TBleGattSession;
  const AKind: TLazBleSessionOperationKind;
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  FSession := ASession;
  FKind := AKind;
end;

end.
