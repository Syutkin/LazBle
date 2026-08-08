unit LazBleGattSession;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSubscription;

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
    FOperations: TList;
    FSubscriptions: TList;
    function Submit(const AKind: TLazBleBackendCommandKind): TBleOperationId;
    function SubmitGattCommand(const ACommand: TLazBleBackendCommand):
      TBleGattOperation;
    function UnsubscribeSubscription(
      const ASubscription: TBleSubscription): TBleGattOperation;
    procedure InvalidateGattState;
    procedure HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
  public
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand);
    destructor Destroy; override;
    function Connect: TBleOperationId;
    function Disconnect: TBleOperationId;
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      TBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      TBleGattOperation;
    function SubscribeAsync(const AServiceUuid, ACharacteristicUuid: string):
      TBleSubscription;
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
  FOperations := TList.Create;
  FSubscriptions := TList.Create;
end;

destructor TBleGattSession.Destroy;
var
  Index: Integer;
begin
  InvalidateGattState;
  for Index := FSubscriptions.Count - 1 downto 0 do
    TObject(FSubscriptions[Index]).Free;
  for Index := FOperations.Count - 1 downto 0 do
    TObject(FOperations[Index]).Free;
  FSubscriptions.Free;
  FOperations.Free;
  inherited Destroy;
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

function TBleGattSession.SubmitGattCommand(
  const ACommand: TLazBleBackendCommand): TBleGattOperation;
var
  OperationId: TBleOperationId;
begin
  OperationId := InvalidBleOperationId;
  if (FState = lbssConnected) and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(ACommand);
  Result := TBleGattOperation.Create(OperationId, ACommand.Kind);
  FOperations.Add(Result);
end;

function TBleGattSession.ReadAsync(
  const AServiceUuid, ACharacteristicUuid: string): TBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  Command.Generation := FGeneration;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.WriteAsync(
  const AServiceUuid, ACharacteristicUuid: string; const AValue: TBytes;
  const AWriteMode: TLazBleWriteMode): TBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckWrite;
  Command.Generation := FGeneration;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.Value := Copy(AValue);
  Command.WriteMode := AWriteMode;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.SubscribeAsync(
  const AServiceUuid, ACharacteristicUuid: string): TBleSubscription;
var
  Command: TLazBleBackendCommand;
  OperationId: TBleOperationId;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckSubscribe;
  Command.Generation := FGeneration;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  OperationId := InvalidBleOperationId;
  if (FState = lbssConnected) and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(Command);
  Result := TBleSubscription.Create(OperationId, FGeneration,
    @UnsubscribeSubscription);
  FSubscriptions.Add(Result);
end;

function TBleGattSession.UnsubscribeSubscription(
  const ASubscription: TBleSubscription): TBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckUnsubscribe;
  Command.Generation := FGeneration;
  Command.DeviceId := FDeviceId;
  Command.SubscriptionId := ASubscription.SubscriptionId;
  Result := SubmitGattCommand(Command);
  ASubscription.BeginUnsubscribe(Result);
end;

procedure TBleGattSession.InvalidateGattState;
var
  Index: Integer;
begin
  for Index := 0 to FOperations.Count - 1 do
    TBleGattOperation(FOperations[Index]).CancelLocally;
  for Index := 0 to FSubscriptions.Count - 1 do
    TBleSubscription(FSubscriptions[Index]).Invalidate;
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
var
  Index: Integer;
begin
  if (AEvent.DeviceId <> '') and (AEvent.DeviceId <> FDeviceId) then
    Exit;
  if (AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration) then
    Exit;

  for Index := 0 to FOperations.Count - 1 do
    TBleGattOperation(FOperations[Index]).HandleBackendEvent(AEvent);
  for Index := 0 to FSubscriptions.Count - 1 do
    TBleSubscription(FSubscriptions[Index]).HandleBackendEvent(AEvent);

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
      begin
        InvalidateGattState;
        FState := lbssDisconnected;
      end;
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled:
      HandleTerminalEvent(AEvent);
  end;
end;

procedure TBleGattSession.HandleBackendShutdown;
begin
  InvalidateGattState;
  FSubmitCommand := nil;
  FState := lbssDisconnected;
end;

end.
