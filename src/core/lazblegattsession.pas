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

  TBleGattSession = class
  private
    FStateLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FEntriesLock: TRTLCriticalSection;
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
    function GetState: TLazBleSessionState;
    function GetGeneration: QWord;
    function GetServices: TLazBleGattServices;
    function GetOnStateChanged: TLazBleSessionStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleSessionStateChangedEvent);
    function Submit(const AKind: TLazBleBackendCommandKind): TBleOperationId;
    function SubmitGattCommand(const ACommand: TLazBleBackendCommand):
      IBleGattOperation;
    procedure OperationCancelled(Sender: TObject);
    function UnsubscribeSubscription(
      const ASubscription: TBleSubscription): IBleGattOperation;
    procedure InvalidateGattState;
    procedure HandleTerminalEvent(const AEvent: TLazBleBackendEvent);
  protected
    constructor Create(const ADeviceId: string;
      const ASubmitCommand: TLazBleSubmitCommand;
      const ACancelOperation: TLazBleCancelOperation);
    function Connect: TBleOperationId;
    function Disconnect: TBleOperationId;
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure HandleBackendShutdown;
    procedure AddStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
    procedure RemoveStateChangedHandler(
      const AHandler: TLazBleSessionStateChangedEvent);
  public
    destructor Destroy; override;
    function ReadAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleGattOperation;
    function WriteAsync(const AServiceUuid, ACharacteristicUuid: string;
      const AValue: TBytes; const AWriteMode: TLazBleWriteMode):
      IBleGattOperation;
    function SubscribeAsync(const AServiceUuid, ACharacteristicUuid: string):
      IBleSubscription;
    function HasService(const AServiceUuid: string): Boolean;
    function TryGetCharacteristic(const AServiceUuid,
      ACharacteristicUuid: string;
      out ACharacteristic: TLazBleGattCharacteristic): Boolean;
    property DeviceId: string read FDeviceId;
    property Generation: QWord read GetGeneration;
    property State: TLazBleSessionState read GetState;
    property Services: TLazBleGattServices read GetServices;
    property OnStateChanged: TLazBleSessionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateInternal(const AOperationId: TBleOperationId;
      const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent);
    constructor CreateTerminal(const AKind: TLazBleBackendCommandKind;
      const AState: TLazBleOperationState; const AErrorMessage: string = '');
    procedure HandleEvent(const AEvent: TLazBleBackendEvent);
    procedure CancelWithoutBackend;
    procedure DetachFromSession;
    function Matches(const AOperationId: TBleOperationId): Boolean;
    function OperationId: TBleOperationId;
  end;

  TBleSubscriptionAccess = class(TBleSubscription)
  public
    constructor CreateInternal(const AOperationId: TBleOperationId;
      const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
    procedure BeginUnsubscribeInternal(const AOperation: IBleGattOperation);
    procedure HandleEvent(const AEvent: TLazBleBackendEvent);
    procedure InvalidateInternal;
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
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOperationId, AKind, AOnCancel);
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
  HandleBackendEvent(AEvent);
end;

procedure TBleGattOperationAccess.CancelWithoutBackend;
begin
  CancelLocally;
end;

procedure TBleGattOperationAccess.DetachFromSession;
begin
  DetachOwner;
end;

function TBleGattOperationAccess.Matches(
  const AOperationId: TBleOperationId): Boolean;
begin
  Result := MatchesOperationId(AOperationId);
end;

function TBleGattOperationAccess.OperationId: TBleOperationId;
begin
  Result := GetOperationId;
end;

constructor TBleSubscriptionAccess.CreateInternal(
  const AOperationId: TBleOperationId; const AGeneration: QWord;
  const AUnsubscribe: TLazBleUnsubscribe);
begin
  inherited Create(AOperationId, AGeneration, AUnsubscribe);
end;

procedure TBleSubscriptionAccess.BeginUnsubscribeInternal(
  const AOperation: IBleGattOperation);
begin
  BeginUnsubscribe(AOperation);
end;

procedure TBleSubscriptionAccess.HandleEvent(
  const AEvent: TLazBleBackendEvent);
begin
  HandleBackendEvent(AEvent);
end;

procedure TBleSubscriptionAccess.InvalidateInternal;
begin
  Invalidate;
end;

procedure TBleSubscriptionAccess.DetachFromSession;
begin
  DetachOwner;
end;

function TBleSubscriptionAccess.OperationId: TBleOperationId;
begin
  Result := GetOperationId;
end;

function TBleSubscriptionAccess.SubscriptionId: TBleSubscriptionId;
begin
  Result := GetSubscriptionId;
end;

function TBleGattSession.GetServices: TLazBleGattServices;
begin
  EnterCriticalSection(FStateLock);
  try
    Result := LazBleCopyGattServices(FServices);
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleGattSession.HasService(const AServiceUuid: string): Boolean;
var
  Service: TLazBleGattService;
begin
  EnterCriticalSection(FStateLock);
  try
    for Service in FServices do
      if SameText(Service.Uuid, AServiceUuid) then
        Exit(True);
    Result := False;
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleGattSession.TryGetCharacteristic(const AServiceUuid,
  ACharacteristicUuid: string;
  out ACharacteristic: TLazBleGattCharacteristic): Boolean;
var
  Characteristic: TLazBleGattCharacteristic;
  Service: TLazBleGattService;
begin
  ACharacteristic := Default(TLazBleGattCharacteristic);
  EnterCriticalSection(FStateLock);
  try
    for Service in FServices do
      if SameText(Service.Uuid, AServiceUuid) then
        for Characteristic in Service.Characteristics do
          if SameText(Characteristic.Uuid, ACharacteristicUuid) then
          begin
            ACharacteristic.Uuid := Characteristic.Uuid;
            ACharacteristic.Properties := Characteristic.Properties;
            ACharacteristic.Descriptors := Copy(Characteristic.Descriptors);
            Exit(True);
          end;
    Result := False;
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleGattSession.GetState: TLazBleSessionState;
begin
  EnterCriticalSection(FStateLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleGattSession.GetGeneration: QWord;
begin
  EnterCriticalSection(FStateLock);
  try
    Result := FGeneration;
  finally
    LeaveCriticalSection(FStateLock);
  end;
end;

function TBleGattSession.GetOnStateChanged:
  TLazBleSessionStateChangedEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattSession.SetOnStateChanged(
  const AHandler: TLazBleSessionStateChangedEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnStateChanged := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattSession.SetState(const AState: TLazBleSessionState);
var
  Handler: TLazBleSessionStateChangedEvent;
  Handlers: TLazBleSessionStateChangedEvents;
begin
  EnterCriticalSection(FStateLock);
  try
    if FState = AState then
      Exit;
    FState := AState;
  finally
    LeaveCriticalSection(FStateLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    Handler := FOnStateChanged;
    Handlers := Copy(FStateChangedHandlers);
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self, AState);
  for Handler in Handlers do
    if Assigned(Handler) then
      Handler(Self, AState);
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
  EnterCriticalSection(FCallbackLock);
  try
    for Handler in FStateChangedHandlers do
      if SameStateChangedHandler(Handler, AHandler) then
        Exit;
    Index := Length(FStateChangedHandlers);
    SetLength(FStateChangedHandlers, Index + 1);
    FStateChangedHandlers[Index] := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleGattSession.RemoveStateChangedHandler(
  const AHandler: TLazBleSessionStateChangedEvent);
var
  Index: Integer;
  MoveIndex: Integer;
begin
  EnterCriticalSection(FCallbackLock);
  try
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
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

constructor TBleGattSession.Create(const ADeviceId: string;
  const ASubmitCommand: TLazBleSubmitCommand;
  const ACancelOperation: TLazBleCancelOperation);
begin
  inherited Create;
  InitCriticalSection(FStateLock);
  InitCriticalSection(FCallbackLock);
  InitCriticalSection(FEntriesLock);
  FDeviceId := ADeviceId;
  FSubmitCommand := ASubmitCommand;
  FCancelOperation := ACancelOperation;
  FState := lbssDisconnected;
  FOperations := TList.Create;
  FSubscriptions := TList.Create;
end;

destructor TBleGattSession.Destroy;
begin
  InvalidateGattState;
  SetOnStateChanged(nil);
  EnterCriticalSection(FCallbackLock);
  try
    FStateChangedHandlers := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  FSubscriptions.Free;
  FOperations.Free;
  DoneCriticalSection(FEntriesLock);
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FStateLock);
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
  OperationId := InvalidBleOperationId;
  if (State = lbssConnected) and Assigned(FSubmitCommand) then
    OperationId := FSubmitCommand(ACommand);
  Operation := TBleGattOperationAccess.CreateInternal(OperationId,
    ACommand.Kind, @OperationCancelled);
  Result := Operation;
  if Operation.State <> lbopPending then
    Exit;
  Entry := TBleGattOperationEntry.Create;
  Entry.Instance := Operation;
  Entry.Operation := Result;
  EnterCriticalSection(FEntriesLock);
  try
    FOperations.Add(Entry);
  finally
    LeaveCriticalSection(FEntriesLock);
  end;
end;

procedure TBleGattSession.OperationCancelled(Sender: TObject);
var
  Index: Integer;
  Entry: TBleGattOperationEntry;
  OperationId: TBleOperationId;
begin
  OperationId := InvalidBleOperationId;
  EnterCriticalSection(FEntriesLock);
  try
    for Index := 0 to FOperations.Count - 1 do
    begin
      Entry := TBleGattOperationEntry(FOperations[Index]);
      if Entry.Instance = Sender then
      begin
        OperationId := TBleGattOperationAccess(Entry.Instance).OperationId;
        Break;
      end;
    end;
  finally
    LeaveCriticalSection(FEntriesLock);
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
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckWrite;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.ServiceUuid := AServiceUuid;
  Command.CharacteristicUuid := ACharacteristicUuid;
  Command.Value := Copy(AValue);
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
  EnterCriticalSection(FEntriesLock);
  try
    FSubscriptions.Add(Entry);
  finally
    LeaveCriticalSection(FEntriesLock);
  end;
end;

function TBleGattSession.UnsubscribeSubscription(
  const ASubscription: TBleSubscription): IBleGattOperation;
var
  Command: TLazBleBackendCommand;
begin
  if ASubscription.State = lbsubPending then
  begin
    if Assigned(FCancelOperation) then
      FCancelOperation(
        TBleSubscriptionAccess(ASubscription).OperationId);
    Result := TBleGattOperationAccess.CreateTerminal(
      lbckUnsubscribe, lbopSucceeded);
    TBleSubscriptionAccess(ASubscription).BeginUnsubscribeInternal(Result);
    Exit;
  end;
  Command := Default(TLazBleBackendCommand);
  Command.Kind := lbckUnsubscribe;
  Command.Generation := Generation;
  Command.DeviceId := FDeviceId;
  Command.SubscriptionId :=
    TBleSubscriptionAccess(ASubscription).SubscriptionId;
  Result := SubmitGattCommand(Command);
  TBleSubscriptionAccess(ASubscription).BeginUnsubscribeInternal(Result);
end;

procedure TBleGattSession.InvalidateGattState;
var
  OperationEntry: TBleGattOperationEntry;
  SubscriptionEntry: TBleSubscriptionEntry;
  Operations: TBleGattOperationInterfaces;
  OperationObjects: TBleGattOperationObjects;
  Subscriptions: TBleSubscriptionInterfaces;
  SubscriptionObjects: TBleSubscriptionObjects;
  Index: Integer;
begin
  Operations := nil;
  OperationObjects := nil;
  Subscriptions := nil;
  SubscriptionObjects := nil;
  EnterCriticalSection(FStateLock);
  try
    FServices := nil;
  finally
    LeaveCriticalSection(FStateLock);
  end;
  EnterCriticalSection(FEntriesLock);
  try
    SetLength(Operations, FOperations.Count);
    SetLength(OperationObjects, FOperations.Count);
    for Index := 0 to FOperations.Count - 1 do
    begin
      OperationEntry := TBleGattOperationEntry(FOperations[Index]);
      Operations[Index] := OperationEntry.Operation;
      OperationObjects[Index] := OperationEntry.Instance;
      OperationEntry.Free;
    end;
    FOperations.Clear;
    SetLength(Subscriptions, FSubscriptions.Count);
    SetLength(SubscriptionObjects, FSubscriptions.Count);
    for Index := 0 to FSubscriptions.Count - 1 do
    begin
      SubscriptionEntry := TBleSubscriptionEntry(FSubscriptions[Index]);
      Subscriptions[Index] := SubscriptionEntry.Subscription;
      SubscriptionObjects[Index] := SubscriptionEntry.Instance;
      SubscriptionEntry.Free;
    end;
    FSubscriptions.Clear;
  finally
    LeaveCriticalSection(FEntriesLock);
  end;
  for Index := 0 to High(OperationObjects) do
  begin
    TBleGattOperationAccess(OperationObjects[Index]).DetachFromSession;
    TBleGattOperationAccess(OperationObjects[Index]).CancelWithoutBackend;
  end;
  for Index := 0 to High(SubscriptionObjects) do
    TBleSubscriptionAccess(SubscriptionObjects[Index]).InvalidateInternal;
end;

function TBleGattSession.Connect: TBleOperationId;
begin
  Result := InvalidBleOperationId;
  if not (State in [lbssDisconnected, lbssError]) then
    Exit;

  EnterCriticalSection(FStateLock);
  try
    FServices := nil;
    Inc(FGeneration);
  finally
    LeaveCriticalSection(FStateLock);
  end;
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
  if not (State in [lbssConnecting, lbssDiscovering, lbssConnected,
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
  OperationEntry: TBleGattOperationEntry;
  SubscriptionEntry: TBleSubscriptionEntry;
  Operations: TBleGattOperationInterfaces;
  OperationObjects: TBleGattOperationObjects;
  Subscriptions: TBleSubscriptionInterfaces;
  SubscriptionObjects: TBleSubscriptionObjects;
  RemoveIndex: Integer;
  Index: Integer;
begin
  Operations := nil;
  OperationObjects := nil;
  Subscriptions := nil;
  SubscriptionObjects := nil;
  if (AEvent.DeviceId <> '') and (AEvent.DeviceId <> FDeviceId) then
    Exit;
  if (AEvent.Generation <> 0) and (AEvent.Generation <> Generation) then
    Exit;

  EnterCriticalSection(FEntriesLock);
  try
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
  finally
    LeaveCriticalSection(FEntriesLock);
  end;

  for Index := 0 to High(OperationObjects) do
  begin
    TBleGattOperationAccess(OperationObjects[Index]).HandleEvent(AEvent);
    if OperationObjects[Index].State = lbopPending then
      Continue;
    TBleGattOperationAccess(OperationObjects[Index]).DetachFromSession;
    EnterCriticalSection(FEntriesLock);
    try
      for RemoveIndex := FOperations.Count - 1 downto 0 do
      begin
        OperationEntry := TBleGattOperationEntry(FOperations[RemoveIndex]);
        if OperationEntry.Instance <> OperationObjects[Index] then
          Continue;
        FOperations.Delete(RemoveIndex);
        OperationEntry.Free;
        Break;
      end;
    finally
      LeaveCriticalSection(FEntriesLock);
    end;
  end;
  for Index := 0 to High(SubscriptionObjects) do
  begin
    TBleSubscriptionAccess(SubscriptionObjects[Index]).HandleEvent(AEvent);
    if not (SubscriptionObjects[Index].State in
      [lbsubInactive, lbsubFailed]) then
      Continue;
    TBleSubscriptionAccess(SubscriptionObjects[Index]).DetachFromSession;
    EnterCriticalSection(FEntriesLock);
    try
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
    finally
      LeaveCriticalSection(FEntriesLock);
    end;
  end;

  case AEvent.Kind of
    lbekConnected:
      if (State = lbssConnecting) and
        (AEvent.OperationId = FConnectOperationId) then
      begin
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
        EnterCriticalSection(FStateLock);
        try
          FServices := LazBleCopyGattServices(AEvent.Services);
        finally
          LeaveCriticalSection(FStateLock);
        end;
        SetState(lbssConnected);
      end;
    lbekDisconnected:
      if State <> lbssDisconnected then
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
