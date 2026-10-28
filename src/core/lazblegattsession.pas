unit LazBleGattSession;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleOperation,
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

  { Device GATT session used by TBleClient and profiles. Services reflect the
    current connection as read-only upstream records and are invalidated when it ends. }
  TBleGattSession = class
  private
    FDeviceId: string;
    FState: TLazBleSessionState;
    FShuttingDown: Boolean;
    FGeneration: QWord;
    FConnectOperationId: TBleOperationId;
    FDiscoveryOperationId: TBleOperationId;
    FDisconnectOperationId: TBleOperationId;
    FSubmitCommand: TLazBleSubmitCommand;
    FCancelOperation: TLazBleCancelOperation;
    FOperations: TList;
    FSubscriptions: TList;
    FServices: TLazBleGattServices;
    FConnectionEstablished, FLastOperationCancelled, FLastOperationFailed: Boolean;
    FErrorCode: Integer;
    FErrorMessage: string;
    FOnStateChanged: TLazBleSessionStateChangedEvent;
    FStateChangedHandlers: TLazBleSessionStateChangedEvents;
    procedure SetState(const AState: TLazBleSessionState);
    function GetState: TLazBleSessionState;
    function GetGeneration: QWord;
    function GetServices: TLazBleGattServices;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetOnStateChanged: TLazBleSessionStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleSessionStateChangedEvent);
    function Submit(const AKind: TLazBleBackendCommandKind): TBleOperationId;
    function SubmitGattCommand(const ACommand: TLazBleBackendCommand):
      IBleGattOperation;
    procedure OperationCancelled(Sender: TObject);
    function UnsubscribeSubscription(
      const ASubscription: TBleSubscription): IBleGattOperation;
    procedure InvalidateGattState(const AForce: Boolean = False);
    procedure HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
  protected
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
    function Connect: TBleOperationId;
    function Disconnect: TBleOperationId;
    procedure CancelConnect;
    procedure CancelDisconnect;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure HandleBackendShutdown;
    procedure PrepareShutdown;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
  public
    destructor Destroy; override;
    { UUID-based requests return failed operations when the session or
      characteristic cannot serve the request. }
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      IBleGattOperation;
    function SubscribeAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleSubscription;
    { Query the currently discovered service tree. }
    function HasService(const AServiceUuid: string): Boolean;
    function TryGetCharacteristic(const AServiceUuid,
      ACharacteristicUuid: string;
      out ACharacteristic: TLazBleGattCharacteristic): Boolean;
    property DeviceId: string read FDeviceId;
    property Generation: QWord read GetGeneration;
    property State: TLazBleSessionState read GetState;
    property Services: TLazBleGattServices read GetServices;
    property LastOperationFailed: Boolean read FLastOperationFailed;
    property LastOperationCancelled: Boolean read FLastOperationCancelled;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property OnStateChanged: TLazBleSessionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateInternal(const AOperationId: TBleOperationId;
      const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord);
    constructor CreateTerminal(const AKind: TLazBleBackendCommandKind;
      const AState: TLazBleOperationState; const AErrorMessage: string = '');
    procedure HandleEvent(const AEvent: TLazBleBackendEvent);
    procedure CancelWithoutBackend;
    procedure DetachFromSession;
    function Matches(const AOperationId: TBleOperationId): Boolean;
    function OperationId: TBleOperationId;
    function OperationKind: TLazBleBackendCommandKind;
  end;

  TBleSubscriptionAccess = class(TBleSubscription)
  public
    constructor CreateInternal(const AOperationId: TBleOperationId;
      const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
    procedure HandleEvent(const AEvent: TLazBleBackendEvent);
    procedure InvalidateInternal(const AForce: Boolean = False);
    procedure DetachCallbacksInternal;
    function CleanupPendingInternal: Boolean;
    procedure BeginShutdownInternal;
    procedure DetachFromSession;
    function OperationId: TBleOperationId;
    function SubscriptionId: TBleSubscriptionId;
  end;

  TBleGattOperationEntry = class
  public
    Operation: IBleGattOperation;
    Instance: TBleGattOperation;
  end;

  TBleSubscriptionEntry = class
  public
    Subscription: IBleSubscription;
    Instance: TBleSubscription;
  end;

  TBleGattOperationInterfaces = array of IBleGattOperation;
  TBleGattOperationObjects = array of TBleGattOperation;
  TBleSubscriptionInterfaces = array of IBleSubscription;
  TBleSubscriptionObjects = array of TBleSubscription;

constructor TBleGattOperationAccess.CreateInternal(
  const AOperationId: TBleOperationId;
  const AKind: TLazBleBackendCommandKind;
  const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord);
begin
  inherited Create(AOperationId, AKind, AOnCancel, AGeneration);
end;

constructor TBleGattOperationAccess.CreateTerminal(
  const AKind: TLazBleBackendCommandKind;
  const AState: TLazBleOperationState; const AErrorMessage: string);
begin
  inherited CreateCompleted(AKind, AState, AErrorMessage);
end;

procedure TBleGattOperationAccess.HandleEvent(
  const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  HandleBackendEvent(AEvent);
end;

procedure TBleGattOperationAccess.CancelWithoutBackend;
begin
  LazBleRequireMainThread;
  CancelLocally;
end;

function TBleGattOperationAccess.OperationKind: TLazBleBackendCommandKind;
begin Result := GetKind; end;

procedure TBleGattOperationAccess.DetachFromSession;
begin
  LazBleRequireMainThread;
  DetachOwner;
end;

function TBleGattOperationAccess.Matches(
  const AOperationId: TBleOperationId): Boolean;
begin
  LazBleRequireMainThread;
  Result := MatchesOperationId(AOperationId);
end;

function TBleGattOperationAccess.OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := GetOperationId;
end;

constructor TBleSubscriptionAccess.CreateInternal(
  const AOperationId: TBleOperationId; const AGeneration: QWord;
  const AUnsubscribe: TLazBleUnsubscribe);
begin
  inherited Create(AOperationId, AGeneration, AUnsubscribe);
end;

procedure TBleSubscriptionAccess.HandleEvent(
  const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  HandleBackendEvent(AEvent);
end;

procedure TBleSubscriptionAccess.InvalidateInternal(const AForce: Boolean);
begin Invalidate(AForce); end;
procedure TBleSubscriptionAccess.DetachCallbacksInternal;
begin DetachCallbacks; end;
function TBleSubscriptionAccess.CleanupPendingInternal: Boolean;
begin Result := CleanupPending; end;

procedure TBleSubscriptionAccess.BeginShutdownInternal;
begin
  BeginShutdown;
end;

procedure TBleSubscriptionAccess.DetachFromSession;
begin
  LazBleRequireMainThread;
  DetachOwner;
end;

function TBleSubscriptionAccess.OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := GetOperationId;
end;

function TBleSubscriptionAccess.SubscriptionId: TBleSubscriptionId;
begin
  LazBleRequireMainThread;
  Result := GetSubscriptionId;
end;

function TBleGattSession.GetServices: TLazBleGattServices;
begin
  LazBleRequireMainThread;
  Result := FServices;
end;

function TBleGattSession.HasService(const AServiceUuid: string): Boolean;
var
  Service: TLazBleGattService;
begin
  LazBleRequireMainThread;
  for Service in FServices do
    if SameText(UTF8Encode(Service.Uuid), AServiceUuid) then
      Exit(True);
  Result := False;
end;

function TBleGattSession.TryGetCharacteristic(const AServiceUuid,
  ACharacteristicUuid: string;
  out ACharacteristic: TLazBleGattCharacteristic): Boolean;
var
  Characteristic: TLazBleGattCharacteristic;
  Service: TLazBleGattService;
begin
  LazBleRequireMainThread;
  ACharacteristic := Default(TLazBleGattCharacteristic);
  for Service in FServices do
    if SameText(UTF8Encode(Service.Uuid), AServiceUuid) then
      for Characteristic in Service.Characteristics do
        if SameText(UTF8Encode(Characteristic.Uuid), ACharacteristicUuid) then
        begin
          ACharacteristic := Characteristic;
          Exit(True);
        end;
  Result := False;
end;

function TBleGattSession.GetState: TLazBleSessionState;
begin
  LazBleRequireMainThread;
  Result := FState;
end;

function TBleGattSession.GetErrorCode: Integer;
begin
  LazBleRequireMainThread;
  Result := FErrorCode;
end;

function TBleGattSession.GetErrorMessage: string;
begin
  LazBleRequireMainThread;
  Result := FErrorMessage;
end;

function TBleGattSession.GetGeneration: QWord;
begin
  LazBleRequireMainThread;
  Result := FGeneration;
end;

function TBleGattSession.GetOnStateChanged:
  TLazBleSessionStateChangedEvent;
begin
  LazBleRequireMainThread;
  Result := FOnStateChanged;
end;

procedure TBleGattSession.SetOnStateChanged(
  const AHandler: TLazBleSessionStateChangedEvent);
begin
  LazBleRequireMainThread;
  FOnStateChanged := AHandler;
end;

procedure TBleGattSession.SetState(const AState: TLazBleSessionState);
var
  Handler: TLazBleSessionStateChangedEvent;
  Handlers: TLazBleSessionStateChangedEvents;
  DeliveryGeneration: QWord;
begin
  LazBleRequireMainThread;
  if FState = AState then
    Exit;
  FState := AState;
  DeliveryGeneration := FGeneration;
  Handler := FOnStateChanged;
  Handlers := Copy(FStateChangedHandlers);
  if Assigned(Handler) then
    Handler(Self, AState);
  for Handler in Handlers do
  begin
    if (FState <> AState) or (FGeneration <> DeliveryGeneration) then Break;
    if Assigned(Handler) then Handler(Self, AState);
  end;
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
  LazBleRequireMainThread;
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
  LazBleRequireMainThread;
  for Index := 0 to High(FStateChangedHandlers) do
    if SameStateChangedHandler(FStateChangedHandlers[Index], AHandler) then
    begin
      for MoveIndex := Index to High(FStateChangedHandlers) - 1 do
        FStateChangedHandlers[MoveIndex] :=
          FStateChangedHandlers[MoveIndex + 1];
      SetLength(FStateChangedHandlers,
        Length(FStateChangedHandlers) - 1);
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

destructor TBleGattSession.Destroy;
var I: Integer;
begin
  for I := 0 to FOperations.Count - 1 do
    TBleGattOperationEntry(FOperations[I]).Operation.OnCompleted := nil;
  for I := 0 to FSubscriptions.Count - 1 do
    TBleSubscriptionAccess(TBleSubscriptionEntry(FSubscriptions[I]).Instance).DetachCallbacksInternal;
  InvalidateGattState(True);
  SetOnStateChanged(nil);
  FStateChangedHandlers := nil;
  FSubscriptions.Free;
  FOperations.Free;
  inherited Destroy;
end;

function TBleGattSession.Submit(
  const AKind: TLazBleBackendCommandKind): TBleOperationId;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Result := InvalidBleOperationId;
  if not Assigned(FSubmitCommand) then
    Exit;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := AKind;
  Command.DeviceId := FDeviceId;
  Command.Generation := Generation;
  Result := FSubmitCommand(Command);
end;

function TBleGattSession.SubmitGattCommand(
  const ACommand: TLazBleBackendCommand): IBleGattOperation;
var
  Entry: TBleGattOperationEntry;
  Operation: TBleGattOperationAccess;
  OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  OperationId := InvalidBleOperationId;
  if (State = lbssConnected) and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(ACommand);
  Operation := TBleGattOperationAccess.CreateInternal(OperationId,
    ACommand.Kind, @OperationCancelled, ACommand.Generation);
  Result := Operation;
  if Operation.State <> lbopPending then
    Exit;
  Entry := TBleGattOperationEntry.Create;
  Entry.Instance := Operation;
  Entry.Operation := Result;
  FOperations.Add(Entry);
end;

procedure TBleGattSession.OperationCancelled(Sender: TObject);
var
  Index: Integer;
  Entry: TBleGattOperationEntry;
  OperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  OperationId := InvalidBleOperationId;
  for Index := 0 to FOperations.Count - 1 do
  begin
    Entry := TBleGattOperationEntry(FOperations[Index]);
    if Entry.Instance = Sender then
    begin
      OperationId := TBleGattOperationAccess(Entry.Instance).OperationId;
      Break;
    end;
  end;
  if (OperationId <> InvalidBleOperationId) and Assigned(FCancelOperation) then
    FCancelOperation(OperationId)
  else
    TBleGattOperationAccess(Sender).CancelWithoutBackend;
end;

function TBleGattSession.ReadAsync(
  const AServiceUuid, ACharacteristicUuid: string): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckRead;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.WriteAsync(
  const AServiceUuid, ACharacteristicUuid: string; const AValue: TBytes;
  const AWriteMode: TLazBleWriteMode): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckWrite;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.Value := AValue; { backend copies the buffer at Submit }
  Command.WriteMode := AWriteMode;
  Result := SubmitGattCommand(Command);
end;

function TBleGattSession.SubscribeAsync(
  const AServiceUuid, ACharacteristicUuid: string): IBleSubscription;
var
  Command: TLazBleBackendCommand;
  Entry: TBleSubscriptionEntry;
  OperationId: TBleOperationId;
  Subscription: TBleSubscriptionAccess;
begin
  LazBleRequireMainThread;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckSubscribe;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  OperationId := InvalidBleOperationId;
  if (State = lbssConnected) and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(Command);
  Subscription := TBleSubscriptionAccess.CreateInternal(OperationId,
    Generation, @UnsubscribeSubscription);
  Result := Subscription;
  if Subscription.State = lbsubFailed then
    Exit;
  Entry := TBleSubscriptionEntry.Create;
  Entry.Instance := Subscription;
  Entry.Subscription := Result;
  FSubscriptions.Add(Entry);
end;

function TBleGattSession.UnsubscribeSubscription(
  const ASubscription: TBleSubscription): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  LazBleRequireMainThread;
  if TBleSubscriptionAccess(ASubscription).SubscriptionId = InvalidBleSubscriptionId then
  begin
    if Assigned(FCancelOperation) then
      FCancelOperation(TBleSubscriptionAccess(ASubscription).OperationId);
    Exit(nil); { Wait for the actual Notify outcome; the token chains cleanup. }
  end;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckUnsubscribe;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.SubscriptionId :=
    TBleSubscriptionAccess(ASubscription).SubscriptionId;
  Result := SubmitGattCommand(Command);
end;

procedure TBleGattSession.InvalidateGattState(const AForce: Boolean);
var
  OpEntry: TBleGattOperationEntry;
  SubEntry: TBleSubscriptionEntry;
  Operations: TBleGattOperationInterfaces;
  Instances: TBleGattOperationObjects;
  Subscriptions: TBleSubscriptionInterfaces;
  Tokens: TBleSubscriptionObjects;
  I, J: Integer;
begin
  LazBleRequireMainThread;
  FServices := nil;
  SetLength(Operations,FOperations.Count); SetLength(Instances,FOperations.Count);
  for I := 0 to FOperations.Count - 1 do
  begin
    OpEntry := TBleGattOperationEntry(FOperations[I]);
    Operations[I] := OpEntry.Operation; Instances[I] := OpEntry.Instance;
  end;
  for I := 0 to High(Operations) do
    if AForce then
    begin
      TBleGattOperationAccess(Instances[I]).DetachFromSession;
      TBleGattOperationAccess(Instances[I]).CancelWithoutBackend;
      for J := FOperations.Count - 1 downto 0 do
      begin
        OpEntry := TBleGattOperationEntry(FOperations[J]);
        if OpEntry.Instance <> Instances[I] then Continue;
        FOperations.Delete(J); OpEntry.Free; Break;
      end;
    end
    else Operations[I].Cancel; { queued calls skip, in-flight calls retain real outcomes }
  SetLength(Subscriptions,FSubscriptions.Count); SetLength(Tokens,FSubscriptions.Count);
  for I := 0 to FSubscriptions.Count - 1 do
  begin
    SubEntry := TBleSubscriptionEntry(FSubscriptions[I]);
    Subscriptions[I] := SubEntry.Subscription; Tokens[I] := SubEntry.Instance;
  end;
  for I := 0 to High(Tokens) do
  begin
    TBleSubscriptionAccess(Tokens[I]).InvalidateInternal(AForce);
    if TBleSubscriptionAccess(Tokens[I]).CleanupPendingInternal then Continue;
    for J := FSubscriptions.Count - 1 downto 0 do
    begin
      SubEntry := TBleSubscriptionEntry(FSubscriptions[J]);
      if SubEntry.Instance <> Tokens[I] then Continue;
      FSubscriptions.Delete(J); SubEntry.Free; Break;
    end;
  end;
end;

function TBleGattSession.Connect: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := InvalidBleOperationId;
  if not (State in [lbssDisconnected, lbssError]) then
    Exit;

  FServices := nil;
  FErrorCode := 0;
  FErrorMessage := '';
  Inc(FGeneration);
  Result := Submit(lbckConnect);
  if Result = InvalidBleOperationId then
  begin
    SetState(lbssError);
    Exit;
  end;
  FLastOperationCancelled := False;
  FLastOperationFailed := False;
  FConnectionEstablished := False;
  FConnectOperationId := Result;
  SetState(lbssConnecting);
end;

function TBleGattSession.Disconnect: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := InvalidBleOperationId;
  if not (State in [lbssConnecting, lbssDiscovering, lbssConnected,
    lbssError]) then
    Exit;

  FErrorCode := 0;
  FErrorMessage := '';
  Result := Submit(lbckDisconnect);
  if Result = InvalidBleOperationId then
    Exit;
  FLastOperationCancelled := False;
  FLastOperationFailed := False;
  FDisconnectOperationId := Result;
  SetState(lbssDisconnecting);
end;

procedure TBleGattSession.CancelConnect;
begin
  LazBleRequireMainThread;
  if not Assigned(FCancelOperation) then Exit;
  if State = lbssConnecting then FCancelOperation(FConnectOperationId)
  else if State = lbssDiscovering then FCancelOperation(FDiscoveryOperationId);
end;

procedure TBleGattSession.CancelDisconnect;
begin
  LazBleRequireMainThread;
  if (State = lbssDisconnecting) and Assigned(FCancelOperation) then
    FCancelOperation(FDisconnectOperationId);
end;

procedure TBleGattSession.HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  if AEvent.Kind = lbekOperationSucceeded then Exit;
  if not ((AEvent.OperationId = FConnectOperationId) or
    (AEvent.OperationId = FDiscoveryOperationId) or
    (AEvent.OperationId = FDisconnectOperationId)) then Exit;
  FLastOperationCancelled := AEvent.Kind = lbekOperationCancelled;
  FLastOperationFailed := AEvent.Kind = lbekOperationFailed;
  FErrorCode := AEvent.ErrorCode;
  FErrorMessage := AEvent.ErrorMessage;
  if FLastOperationCancelled then
  begin
    if AEvent.OperationId = FDisconnectOperationId then
      if FConnectionEstablished then SetState(lbssConnected) else SetState(lbssDisconnected)
    else if FConnectionEstablished then
      { Discovery was cancelled, but the native connection remains. An explicit
        Disconnect is available from Error; do not simulate a disconnect. }
      SetState(lbssError)
    else SetState(lbssDisconnected);
  end
  else SetState(lbssError);
end;

procedure TBleGattSession.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  OperationEntry: TBleGattOperationEntry;
  SubscriptionEntry: TBleSubscriptionEntry;
  Operations: TBleGattOperationInterfaces;
  OperationObjects: TBleGattOperationObjects;
  Subscriptions: TBleSubscriptionInterfaces;
  SubscriptionObjects: TBleSubscriptionObjects;
  RemoveIndex: Integer;
  Index: Integer;
begin
  LazBleRequireMainThread;
  Operations := nil;
  OperationObjects := nil;
  Subscriptions := nil;
  SubscriptionObjects := nil;
  if (AEvent.DeviceId <> '') and (AEvent.DeviceId <> FDeviceId) then
    Exit;

  SetLength(Operations, FOperations.Count);
  SetLength(OperationObjects, FOperations.Count);
  for Index := 0 to FOperations.Count - 1 do
  begin
    OperationEntry := TBleGattOperationEntry(FOperations[Index]);
    Operations[Index] := OperationEntry.Operation;
    OperationObjects[Index] := OperationEntry.Instance;
  end;
  SetLength(Subscriptions, FSubscriptions.Count);
  SetLength(SubscriptionObjects, FSubscriptions.Count);
  for Index := 0 to FSubscriptions.Count - 1 do
  begin
    SubscriptionEntry := TBleSubscriptionEntry(FSubscriptions[Index]);
    Subscriptions[Index] := SubscriptionEntry.Subscription;
    SubscriptionObjects[Index] := SubscriptionEntry.Instance;
  end;

  for Index := 0 to High(OperationObjects) do
  begin
    if (TBleGattOperationAccess(OperationObjects[Index]).OperationKind = lbckUnsubscribe) and
      (AEvent.OperationId = TBleGattOperationAccess(OperationObjects[Index]).OperationId) and
      (AEvent.Kind in [lbekOperationFailed, lbekOperationCancelled]) then
    begin
      if (State = lbssConnected) and
        (TBleGattOperationAccess(OperationObjects[Index]).OperationGeneration = Generation) then
      begin
        Disconnect;
        FLastOperationFailed := True;
        FErrorCode := AEvent.ErrorCode;
        FErrorMessage := AEvent.ErrorMessage;
      end;
    end;
    TBleGattOperationAccess(OperationObjects[Index]).HandleEvent(AEvent);
    if OperationObjects[Index].State = lbopPending then
      Continue;
    TBleGattOperationAccess(OperationObjects[Index]).DetachFromSession;
    for RemoveIndex := FOperations.Count - 1 downto 0 do
    begin
      OperationEntry := TBleGattOperationEntry(FOperations[RemoveIndex]);
      if OperationEntry.Instance <> OperationObjects[Index] then
        Continue;
      FOperations.Delete(RemoveIndex);
      OperationEntry.Free;
      Break;
    end;
  end;
  for Index := 0 to High(SubscriptionObjects) do
  begin
    TBleSubscriptionAccess(SubscriptionObjects[Index]).HandleEvent(AEvent);
    if not (SubscriptionObjects[Index].State in
      [lbsubInactive, lbsubFailed]) or
      TBleSubscriptionAccess(SubscriptionObjects[Index]).CleanupPendingInternal then
      Continue;
    TBleSubscriptionAccess(SubscriptionObjects[Index]).DetachFromSession;
    for RemoveIndex := FSubscriptions.Count - 1 downto 0 do
    begin
      SubscriptionEntry := TBleSubscriptionEntry(
        FSubscriptions[RemoveIndex]);
      if SubscriptionEntry.Instance <> SubscriptionObjects[Index] then
        Continue;
      FSubscriptions.Delete(RemoveIndex);
      SubscriptionEntry.Free;
      Break;
    end;
  end;

  { Command IDs/own generations route late results before the current-session
    filter. Reconnecting must not orphan an accepted old command. }
  if (AEvent.Generation <> 0) and (AEvent.Generation <> Generation) then Exit;
  if FShuttingDown then
  begin
    { A requested Disconnect still reports a real failure/cancellation. Other
      session pipelines close at ShutdownCompleted without starting discovery. }
    if (AEvent.OperationId = FDisconnectOperationId) and
      (AEvent.Kind in [lbekOperationFailed, lbekOperationCancelled]) then
      HandleTerminalEvent(AEvent);
    Exit;
  end;
  case AEvent.Kind of
    lbekConnected:
      if (State = lbssConnecting) and
        (AEvent.OperationId = FConnectOperationId) then
      begin
        FConnectionEstablished := True;
        FLastOperationCancelled := False;
        FLastOperationFailed := False;
        FDiscoveryOperationId := Submit(lbckDiscoverServices);
        if FDiscoveryOperationId = InvalidBleOperationId then
          SetState(lbssError)
        else
          SetState(lbssDiscovering);
      end;
    lbekServicesDiscovered:
      if (State = lbssDiscovering) and
        (AEvent.OperationId = FDiscoveryOperationId) then
      begin
        FServices := AEvent.Services;
        SetState(lbssConnected);
      end;
    lbekDisconnected:
      if State <> lbssDisconnected then
      begin
        FConnectionEstablished := False;
        FLastOperationCancelled := False;
        FServices := nil;
        SetState(lbssDisconnected);
        InvalidateGattState;
      end;
    lbekOperationSucceeded,
    lbekOperationFailed,
    lbekOperationCancelled:
      HandleTerminalEvent(AEvent);
  end;

end;

procedure TBleGattSession.PrepareShutdown;
var I: Integer;
begin
  LazBleRequireMainThread;
  FShuttingDown := True;
  for I := 0 to FSubscriptions.Count - 1 do
    TBleSubscriptionAccess(TBleSubscriptionEntry(FSubscriptions[I]).Instance).BeginShutdownInternal;
end;

procedure TBleGattSession.HandleBackendShutdown;
begin
  LazBleRequireMainThread;
  FConnectionEstablished := False;
  InvalidateGattState(True);
  FSubmitCommand := nil;
  FCancelOperation := nil;
  SetState(lbssDisconnected);
end;

end.
