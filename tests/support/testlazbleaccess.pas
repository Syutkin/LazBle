unit TestLazBleAccess;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes,
  LazBleGattSession;

function LazBleTestCreateSession(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation): TBleGattSession;
function LazBleTestConnect(const ASession: TBleGattSession): TBleOperationId;
function LazBleTestDisconnect(
  const ASession: TBleGattSession): TBleOperationId;

implementation

type
  TTestBleGattSessionAccess = class(TBleGattSession)
  public
    constructor CreateInternal(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
    function ConnectInternal: TBleOperationId;
    function DisconnectInternal: TBleOperationId;
  end;

constructor TTestBleGattSessionAccess.CreateInternal(
  const ADeviceId: string; const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation);
begin
  inherited Create(ADeviceId, ASubmitCommand, ACancelOperation);
end;

function TTestBleGattSessionAccess.ConnectInternal: TBleOperationId;
begin
  Result := Connect;
end;

function TTestBleGattSessionAccess.DisconnectInternal: TBleOperationId;
begin
  Result := Disconnect;
end;

function LazBleTestCreateSession(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation): TBleGattSession;
begin
  Result := TTestBleGattSessionAccess.CreateInternal(ADeviceId,
    ASubmitCommand, ACancelOperation);
end;

function LazBleTestConnect(const ASession: TBleGattSession): TBleOperationId;
begin
  Result := TTestBleGattSessionAccess(ASession).ConnectInternal;
end;

function LazBleTestDisconnect(
  const ASession: TBleGattSession): TBleOperationId;
begin
  Result := TTestBleGattSessionAccess(ASession).DisconnectInternal;
end;

end.
