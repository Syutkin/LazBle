unit LazBleGattSession;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

type
  TLazBleSessionState = (
    lbssDisconnected,
    lbssConnecting,
    lbssDiscovering,
    lbssConnected,
    lbssDisconnecting,
    lbssError
  );

  TLazBleSubmitCommand = function(
    const ACommand: TLazBleBackendCommand): TBleOperationId of object;

  TBleGattSession = class
  private
    FDeviceId: string;
    FState: TLazBleSessionState;
    FGeneration: QWord;
    FConnectOperationId: TBleOperationId;
    FDiscoveryOperationId: TBleOperationId;
    FDisconnectOperationId: TBleOperationId;
    FSubmitCommand: TLazBleSubmitCommand;
    function Submit(const AKind: TLazBleBackendCommandKind): TBleOperationId;
    procedure HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
  public
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand);
    function Connect: TBleOperationId;
    function Disconnect: TBleOperationId;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure HandleBackendShutdown;
    property DeviceId: string read FDeviceId;
    property Generation: QWord read FGeneration;
    property State: TLazBleSessionState read FState;
  end;

implementation

constructor TBleGattSession.Create(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand);
begin
  inherited Create;
  FDeviceId := ADeviceId;
  FSubmitCommand := ASubmitCommand;
  FState := lbssDisconnected;
end;

function TBleGattSession.Submit(
  const AKind: TLazBleBackendCommandKind): TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  Result := InvalidBleOperationId;
  if not Assigned(FSubmitCommand) then
    Exit;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := AKind;
  Command.DeviceId := FDeviceId;
  Command.Generation := FGeneration;
  Result := FSubmitCommand(Command);
end;

function TBleGattSession.Connect: TBleOperationId;
begin
  Result := InvalidBleOperationId;
  if not (FState in [lbssDisconnected, lbssError]) then
    Exit;

  Inc(FGeneration);
  Result := Submit(lbckConnect);
  if Result = InvalidBleOperationId then
  begin
    FState := lbssError;
    Exit;
  end;
  FConnectOperationId := Result;
  FState := lbssConnecting;
end;

function TBleGattSession.Disconnect: TBleOperationId;
begin
  Result := InvalidBleOperationId;
  if not (FState in [lbssConnecting, lbssDiscovering, lbssConnected,
    lbssError]) then
    Exit;

  Result := Submit(lbckDisconnect);
  if Result = InvalidBleOperationId then
    Exit;
  FDisconnectOperationId := Result;
  FState := lbssDisconnecting;
end;

procedure TBleGattSession.HandleTerminalEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if AEvent.Kind = lbekOperationSucceeded then
    Exit;

  if (AEvent.OperationId = FConnectOperationId) or
    (AEvent.OperationId = FDiscoveryOperationId) then
  begin
    if AEvent.Kind = lbekOperationCancelled then
      FState := lbssDisconnected
    else
      FState := lbssError;
  end
  else if AEvent.OperationId = FDisconnectOperationId then
  begin
    if AEvent.Kind = lbekOperationFailed then
      FState := lbssError
    else
      FState := lbssDisconnected;
  end;
end;

procedure TBleGattSession.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if (AEvent.DeviceId <> '') and (AEvent.DeviceId <> FDeviceId) then
    Exit;
  if (AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration) then
    Exit;

  case AEvent.Kind of
    lbekConnected:
      if (FState = lbssConnecting) and
        (AEvent.OperationId = FConnectOperationId) then
      begin
        FDiscoveryOperationId := Submit(lbckDiscoverServices);
        if FDiscoveryOperationId = InvalidBleOperationId then
          FState := lbssError
        else
          FState := lbssDiscovering;
      end;
    lbekServicesDiscovered:
      if (FState = lbssDiscovering) and
        (AEvent.OperationId = FDiscoveryOperationId) then
        FState := lbssConnected;
    lbekDisconnected:
      if FState <> lbssDisconnected then
        FState := lbssDisconnected;
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled:
      HandleTerminalEvent(AEvent);
  end;
end;

procedure TBleGattSession.HandleBackendShutdown;
begin
  FSubmitCommand := nil;
  FState := lbssDisconnected;
end;

end.
