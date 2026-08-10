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

  TLazBleSessionStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleSessionState) of object;
  TLazBleSessionStateChangedEvents = array of
    TLazBleSessionStateChangedEvent;

  TLazBleSubmitCommand = function(
    const ACommand: TLazBleBackendCommand): TBleOperationId of object;
  TLazBleCancelOperation = procedure(
    const AOperationId: TBleOperationId) of object;

  TBleGattSession = class
  private
    FDeviceId: string;
    FState: TLazBleSessionState;
    FGeneration: QWord;
    FConnectOperationId: TBleOperationId;
    FDiscoveryOperationId: TBleOperationId;
    FDisconnectOperationId: TBleOperationId;
    FSubmitCommand: TLazBleSubmitCommand;
    FCancelOperation: TLazBleCancelOperation;
    FOperations: TList;
    FSubscriptions: TList;
    FServices: TLazBleGattServices;
    FOnStateChanged: TLazBleSessionStateChangedEvent;
    FStateChangedHandlers: TLazBleSessionStateChangedEvents;
    procedure SetState(const AState: TLazBleSessionState);
    function GetServices: TLazBleGattServices;
    function Submit(const AKind: TLazBleBackendCommandKind): TBleOperationId;
    function SubmitGattCommand(const ACommand: TLazBleBackendCommand):
      TBleGattOperation;
    function UnsubscribeSubscription(
      const ASubscription: TBleSubscription): TBleGattOperation;
    procedure InvalidateGattState;
    procedure HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
  public
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
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
    procedure CancelOperation(const AOperation: TBleGattOperation);
    procedure CancelSubscription(const ASubscription: TBleSubscription);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure HandleBackendShutdown;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
    property DeviceId: string read FDeviceId;
    property Generation: QWord read FGeneration;
    property State: TLazBleSessionState read FState;
    property Services: TLazBleGattServices read GetServices;
    property OnStateChanged: TLazBleSessionStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

implementation

function TBleGattSession.GetServices: TLazBleGattServices;
begin
  Result := LazBleCopyGattServices(FServices);
end;

procedure TBleGattSession.SetState(const AState: TLazBleSessionState);
var
  Handler: TLazBleSessionStateChangedEvent;
  Handlers: TLazBleSessionStateChangedEvents;
begin
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
  Handlers := Copy(FStateChangedHandlers);
  for Handler in Handlers do
    if Assigned(Handler) then
      Handler(Self, FState);
end;

function SameStateChangedHandler(const AFirst,
  ASecond: TLazBleSessionStateChangedEvent): Boolean;
begin
  Result := (TMethod(AFirst).Code = TMethod(ASecond).Code) and
    (TMethod(AFirst).Data = TMethod(ASecond).Data);
end;

procedure TBleGattSession.AddStateChangedHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
var
  Handler: TLazBleSessionStateChangedEvent;
  Index: Integer;
begin
  if not Assigned(AHandler) then
    Exit;
  for Handler in FStateChangedHandlers do
    if SameStateChangedHandler(Handler, AHandler) then
      Exit;
  Index := Length(FStateChangedHandlers);
  SetLength(FStateChangedHandlers, Index + 1);
  FStateChangedHandlers[Index] := AHandler;
end;

procedure TBleGattSession.RemoveStateChangedHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
var
  Index: Integer;
  MoveIndex: Integer;
begin
  for Index := 0 to High(FStateChangedHandlers) do
    if SameStateChangedHandler(FStateChangedHandlers[Index], AHandler) then
    begin
      for MoveIndex := Index to High(FStateChangedHandlers) - 1 do
        FStateChangedHandlers[MoveIndex] :=
          FStateChangedHandlers[MoveIndex + 1];
      SetLength(FStateChangedHandlers, Length(FStateChangedHandlers) - 1);
      Exit;
    end;
end;

constructor TBleGattSession.Create(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation);
begin
  inherited Create;
  FDeviceId := ADeviceId;
  FSubmitCommand := ASubmitCommand;
  FCancelOperation := ACancelOperation;
  FState := lbssDisconnected;
  FOperations := TList.Create;
  FSubscriptions := TList.Create;
end;

procedure TBleGattSession.CancelOperation(
  const AOperation: TBleGattOperation);
begin
  if Assigned(AOperation) and (AOperation.State = lbosPending) and
    Assigned(FCancelOperation) then
    FCancelOperation(AOperation.OperationId);
end;

procedure TBleGattSession.CancelSubscription(
  const ASubscription: TBleSubscription);
begin
  if Assigned(ASubscription) and
    (ASubscription.State = lbsubPending) and Assigned(FCancelOperation) then
    FCancelOperation(ASubscription.OperationId);
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
  FServices := nil;
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

  FServices := nil;
  Inc(FGeneration);
  Result := Submit(lbckConnect);
  if Result = InvalidBleOperationId then
  begin
    SetState(lbssError);
    Exit;
  end;
  FConnectOperationId := Result;
  SetState(lbssConnecting);
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
  SetState(lbssDisconnecting);
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
      SetState(lbssDisconnected)
    else
      SetState(lbssError);
  end
  else if AEvent.OperationId = FDisconnectOperationId then
  begin
    if AEvent.Kind = lbekOperationFailed then
      SetState(lbssError)
    else
      SetState(lbssDisconnected);
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
          SetState(lbssError)
        else
          SetState(lbssDiscovering);
      end;
    lbekServicesDiscovered:
      if (FState = lbssDiscovering) and
        (AEvent.OperationId = FDiscoveryOperationId) then
      begin
        FServices := LazBleCopyGattServices(AEvent.Services);
        SetState(lbssConnected);
      end;
    lbekDisconnected:
      if FState <> lbssDisconnected then
      begin
        InvalidateGattState;
        SetState(lbssDisconnected);
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
  FCancelOperation := nil;
  SetState(lbssDisconnected);
end;

end.
