unit LazBleGattSubscription;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleGattOperation;

type
  TLazBleSubscriptionState = (
    lbsubPending,
    lbsubActive,
    lbsubUnsubscribing,
    lbsubInactive,
    lbsubFailed
  );

  TLazBleDataEvent = procedure(Sender: TObject; const AValue: TBytes) of object;
  TLazBleSubscriptionStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleSubscriptionState) of object;

  IBleSubscription = interface
    ['{BCA47713-79BD-43C4-BADC-84A6AEB20CB4}']
    function GetState: TLazBleSubscriptionState;
    function GetOnData: TLazBleDataEvent;
    procedure SetOnData(const AHandler: TLazBleDataEvent);
    function GetOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleSubscriptionStateChangedEvent);
    function Unsubscribe: IBleGattOperation;
    property State: TLazBleSubscriptionState read GetState;
    property OnData: TLazBleDataEvent read GetOnData write SetOnData;
    property OnStateChanged: TLazBleSubscriptionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

  TBleSubscription = class;
  TLazBleUnsubscribe = function(
    const ASubscription: TBleSubscription): IBleGattOperation of object;

  TBleSubscription = class(TInterfacedObject, IBleSubscription)
  private
    FLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
    FOperationId: TBleOperationId;
    FSubscriptionId: TBleSubscriptionId;
    FGeneration: QWord;
    FState: TLazBleSubscriptionState;
    FUnsubscribe: TLazBleUnsubscribe;
    FUnsubscribeOperation: IBleGattOperation;
    FOnData: TLazBleDataEvent;
    FOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    function GetState: TLazBleSubscriptionState;
    function GetOnData: TLazBleDataEvent;
    procedure SetOnData(const AHandler: TLazBleDataEvent);
    function GetOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    procedure SetOnStateChanged(
      const AHandler: TLazBleSubscriptionStateChangedEvent);
    procedure SetState(const AState: TLazBleSubscriptionState);
    procedure UnsubscribeCompleted(Sender: TObject);
  protected
    constructor Create(const AOperationId: TBleOperationId;
      const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
    procedure BeginUnsubscribe(const AOperation: IBleGattOperation);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure Invalidate;
    procedure DetachOwner;
    function GetOperationId: TBleOperationId;
    function GetSubscriptionId: TBleSubscriptionId;
    function GetGeneration: QWord;
  public
    destructor Destroy; override;
    function Unsubscribe: IBleGattOperation;
    property State: TLazBleSubscriptionState read GetState;
    property OnData: TLazBleDataEvent read GetOnData write SetOnData;
    property OnStateChanged: TLazBleSubscriptionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateTerminal(const AState: TLazBleOperationState;
      const AErrorMessage: string);
  end;

constructor TBleGattOperationAccess.CreateTerminal(
  const AState: TLazBleOperationState; const AErrorMessage: string);
begin
  inherited CreateCompleted(lbckUnsubscribe, AState, AErrorMessage);
end;

constructor TBleSubscription.Create(const AOperationId: TBleOperationId;
  const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
begin
  inherited Create;
  InitCriticalSection(FLock);
  InitCriticalSection(FCallbackLock);
  FOperationId := AOperationId;
  FGeneration := AGeneration;
  FUnsubscribe := AUnsubscribe;
  if AOperationId = InvalidBleOperationId then
    FState := lbsubFailed
  else
    FState := lbsubPending;
end;

destructor TBleSubscription.Destroy;
begin
  if Assigned(FUnsubscribeOperation) then
    FUnsubscribeOperation.OnCompleted := nil;
  EnterCriticalSection(FCallbackLock);
  try
    FOnData := nil;
    FOnStateChanged := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  EnterCriticalSection(FLock);
  try
    FUnsubscribe := nil;
    FUnsubscribeOperation := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TBleSubscription.GetState: TLazBleSubscriptionState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FState;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleSubscription.GetOnData: TLazBleDataEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnData;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleSubscription.SetOnData(const AHandler: TLazBleDataEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnData := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

function TBleSubscription.GetOnStateChanged:
  TLazBleSubscriptionStateChangedEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleSubscription.SetOnStateChanged(
  const AHandler: TLazBleSubscriptionStateChangedEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnStateChanged := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleSubscription.SetState(
  const AState: TLazBleSubscriptionState);
var
  Handler: TLazBleSubscriptionStateChangedEvent;
begin
  EnterCriticalSection(FLock);
  try
    if FState = AState then
      Exit;
    FState := AState;
  finally
    LeaveCriticalSection(FLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    Handler := FOnStateChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self, AState);
end;

function TBleSubscription.Unsubscribe: IBleGattOperation;
var
  Handler: TLazBleUnsubscribe;
  CurrentState: TLazBleSubscriptionState;
begin
  EnterCriticalSection(FLock);
  try
    Result := FUnsubscribeOperation;
    if Assigned(Result) then
      Exit;
    Handler := FUnsubscribe;
    CurrentState := FState;
  finally
    LeaveCriticalSection(FLock);
  end;

  if CurrentState = lbsubInactive then
    Result := TBleGattOperationAccess.CreateTerminal(lbopSucceeded, '')
  else if CurrentState = lbsubFailed then
    Result := TBleGattOperationAccess.CreateTerminal(lbopFailed,
      'BLE subscription is not active')
  else if Assigned(Handler) then
    Result := Handler(Self)
  else
    Result := TBleGattOperationAccess.CreateTerminal(lbopFailed,
      'BLE subscription is detached');

  EnterCriticalSection(FLock);
  try
    if not Assigned(FUnsubscribeOperation) then
      FUnsubscribeOperation := Result
    else
      Result := FUnsubscribeOperation;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBleSubscription.BeginUnsubscribe(
  const AOperation: IBleGattOperation);
begin
  EnterCriticalSection(FLock);
  try
    FUnsubscribeOperation := AOperation;
  finally
    LeaveCriticalSection(FLock);
  end;
  SetState(lbsubUnsubscribing);
  AOperation.OnCompleted := @UnsubscribeCompleted;
end;

procedure TBleSubscription.UnsubscribeCompleted(Sender: TObject);
var
  Operation: IBleGattOperation;
begin
  EnterCriticalSection(FLock);
  try
    Operation := FUnsubscribeOperation;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not Assigned(Operation) then
    Exit;
  Operation.OnCompleted := nil;
  if Operation.State = lbopFailed then
    SetState(lbsubFailed)
  else
    SetState(lbsubInactive);
end;

procedure TBleSubscription.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
var
  DataHandler: TLazBleDataEvent;
  Value: TBytes;
begin
  if (AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration) then
    Exit;

  if (AEvent.OperationId = FOperationId) and
    (State in [lbsubPending, lbsubActive]) then
    case AEvent.Kind of
      lbekSubscribed:
        begin
          EnterCriticalSection(FLock);
          try
            FSubscriptionId := AEvent.SubscriptionId;
          finally
            LeaveCriticalSection(FLock);
          end;
          SetState(lbsubActive);
        end;
      lbekOperationFailed,
      lbekOperationCancelled:
        SetState(lbsubFailed);
    end;

  if (State = lbsubActive) and (AEvent.Kind = lbekNotification) and
    (AEvent.SubscriptionId = GetSubscriptionId) then
  begin
    Value := Copy(AEvent.Value);
    EnterCriticalSection(FCallbackLock);
    try
      DataHandler := FOnData;
    finally
      LeaveCriticalSection(FCallbackLock);
    end;
    if Assigned(DataHandler) then
      DataHandler(Self, Value);
  end;
end;

procedure TBleSubscription.Invalidate;
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnData := nil;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  DetachOwner;
  SetState(lbsubInactive);
  SetOnStateChanged(nil);
end;

procedure TBleSubscription.DetachOwner;
begin
  EnterCriticalSection(FLock);
  try
    FUnsubscribe := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleSubscription.GetOperationId: TBleOperationId;
begin
  Result := FOperationId;
end;

function TBleSubscription.GetSubscriptionId: TBleSubscriptionId;
begin
  EnterCriticalSection(FLock);
  try
    Result := FSubscriptionId;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBleSubscription.GetGeneration: QWord;
begin
  Result := FGeneration;
end;

end.
