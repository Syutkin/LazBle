unit LazBleGattSubscription;

{$mode objfpc}{$H+}

interface

uses SysUtils, LazBleTypes, LazBleOperation, LazBleGattOperation;

type
  TLazBleSubscriptionState = (lbsubPending, lbsubActive, lbsubUnsubscribing,
    lbsubInactive, lbsubFailed);
  TLazBleDataEvent = procedure(Sender: TObject; const AValue: TBytes) of object;
  TLazBleSubscriptionStateChangedEvent = procedure(Sender: TObject;
    const AState: TLazBleSubscriptionState) of object;

  { Main-thread notification token. Early values are dropped, not replayed.
    Unsubscribe retires delivery immediately and awaits actual native cleanup,
    including a Notify that is still pending. Its cleanup cannot be cancelled. }
  IBleSubscription = interface
    ['{E0A9178B-250E-490D-9CD3-514A13367F44}']
    function GetState: TLazBleSubscriptionState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetOnData: TLazBleDataEvent;
    procedure SetOnData(const AHandler: TLazBleDataEvent);
    function GetOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    procedure SetOnStateChanged(const AHandler: TLazBleSubscriptionStateChangedEvent);
    function Unsubscribe: IBleGattOperation;
    property State: TLazBleSubscriptionState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    { Payload and its nested data are read-only for the receiver. }
    property OnData: TLazBleDataEvent read GetOnData write SetOnData;
    property OnStateChanged: TLazBleSubscriptionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

  TBleSubscription = class;
  TLazBleUnsubscribe = function(const ASubscription: TBleSubscription):
    IBleGattOperation of object;

  TBleSubscription = class(TInterfacedObject, IBleSubscription)
  private
    FOperationId: TBleOperationId;
    FSubscriptionId: TBleSubscriptionId;
    FGeneration: QWord;
    FState: TLazBleSubscriptionState;
    FClosing: Boolean;
    FErrorCode: Integer;
    FErrorMessage: string;
    FUnsubscribe: TLazBleUnsubscribe;
    FUnsubscribeOperation, FNativeUnsubscribeOperation: IBleGattOperation;
    FUnsubscribeObject: TBleGattOperation;
    FOnData: TLazBleDataEvent;
    FOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    function GetState: TLazBleSubscriptionState;
    function GetErrorCode: Integer;
    function GetErrorMessage: string;
    function GetOnData: TLazBleDataEvent;
    procedure SetOnData(const AHandler: TLazBleDataEvent);
    function GetOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    procedure SetOnStateChanged(const AHandler: TLazBleSubscriptionStateChangedEvent);
    procedure SetState(const AState: TLazBleSubscriptionState);
    procedure StartNativeUnsubscribe;
    procedure UnsubscribeCompleted(Sender: TObject);
    procedure FinishUnsubscribe(const AState: TLazBleOperationState;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
  protected
    constructor CreateFailed(const AErrorCode: Integer; const AErrorMessage: string);
    constructor Create(const AOperationId: TBleOperationId;
      const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure Invalidate(const AForce: Boolean = False);
    procedure DetachCallbacks;
    function CleanupPending: Boolean;
    procedure BeginShutdown;
    procedure DetachOwner;
    function GetOperationId: TBleOperationId;
    function GetSubscriptionId: TBleSubscriptionId;
    function GetGeneration: QWord;
  public
    destructor Destroy; override;
    function Unsubscribe: IBleGattOperation;
    property State: TLazBleSubscriptionState read GetState;
    property ErrorCode: Integer read GetErrorCode;
    property ErrorMessage: string read GetErrorMessage;
    property OnData: TLazBleDataEvent read GetOnData write SetOnData;
    property OnStateChanged: TLazBleSubscriptionStateChangedEvent
      read GetOnStateChanged write SetOnStateChanged;
  end;

implementation

type
  TUnsubscribeOperation = class(TBleGattOperation)
  public
    constructor Create;
    procedure Finish(AState: TLazBleOperationState; ACode: Integer; const Text: string);
  end;

constructor TUnsubscribeOperation.Create;
begin
  inherited CreatePending(lbckUnsubscribe);
end;

procedure TUnsubscribeOperation.Finish(AState: TLazBleOperationState;
  ACode: Integer; const Text: string);
begin
  Complete(AState, ACode, Text);
end;

constructor TBleSubscription.Create(const AOperationId: TBleOperationId;
  const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
begin
  inherited Create;
  FOperationId := AOperationId;
  FGeneration := AGeneration;
  FUnsubscribe := AUnsubscribe;
  if AOperationId = InvalidBleOperationId then
  begin
    FState := lbsubFailed;
    FErrorCode := LazBleErrorInvalidState;
    FErrorMessage := 'BLE subscription could not be started';
  end
  else FState := lbsubPending;
end;

constructor TBleSubscription.CreateFailed(const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create;
  FState := lbsubFailed;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
end;

destructor TBleSubscription.Destroy;
begin
  if FNativeUnsubscribeOperation <> nil then FNativeUnsubscribeOperation.OnCompleted := nil;
  inherited Destroy;
end;

function TBleSubscription.GetState: TLazBleSubscriptionState;
begin LazBleRequireMainThread; Result := FState; end;
function TBleSubscription.GetErrorCode: Integer;
begin LazBleRequireMainThread; Result := FErrorCode; end;
function TBleSubscription.GetErrorMessage: string;
begin LazBleRequireMainThread; Result := FErrorMessage; end;
function TBleSubscription.GetOnData: TLazBleDataEvent;
begin LazBleRequireMainThread; Result := FOnData; end;
procedure TBleSubscription.SetOnData(const AHandler: TLazBleDataEvent);
begin LazBleRequireMainThread; FOnData := AHandler; end;
function TBleSubscription.GetOnStateChanged: TLazBleSubscriptionStateChangedEvent;
begin LazBleRequireMainThread; Result := FOnStateChanged; end;
procedure TBleSubscription.SetOnStateChanged(const AHandler: TLazBleSubscriptionStateChangedEvent);
begin LazBleRequireMainThread; FOnStateChanged := AHandler; end;

procedure TBleSubscription.SetState(const AState: TLazBleSubscriptionState);
begin
  LazBleRequireMainThread;
  if FState = AState then Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then FOnStateChanged(Self, AState);
end;

function TBleSubscription.Unsubscribe: IBleGattOperation;
var
  WasPending: Boolean;
begin
  LazBleRequireMainThread;
  if FUnsubscribeOperation <> nil then Exit(FUnsubscribeOperation);
  WasPending := FState = lbsubPending;
  FUnsubscribeObject := TUnsubscribeOperation.Create;
  FUnsubscribeOperation := FUnsubscribeObject;
  Result := FUnsubscribeOperation;
  case FState of
    lbsubInactive: FinishUnsubscribe(lbopSucceeded);
    lbsubFailed: FinishUnsubscribe(lbopFailed, FErrorCode, FErrorMessage);
  else
    begin
      { Set state before invoking any handler, so no value can escape after
        Unsubscribe, even if native Notify is already in flight. }
      SetState(lbsubUnsubscribing);
      if WasPending then
      begin
        if Assigned(FUnsubscribe) then
          FUnsubscribe(Self) { asks the session to cancel queued Notify }
        else FinishUnsubscribe(lbopFailed, LazBleErrorInvalidState, 'Subscription is detached');
      end
      else StartNativeUnsubscribe;
    end;
  end;
end;

procedure TBleSubscription.StartNativeUnsubscribe;
begin
  if FNativeUnsubscribeOperation <> nil then Exit;
  if not Assigned(FUnsubscribe) then
  begin
    FinishUnsubscribe(lbopFailed, LazBleErrorInvalidState, 'Subscription is detached');
    Exit;
  end;
  FNativeUnsubscribeOperation := FUnsubscribe(Self);
  if FNativeUnsubscribeOperation = nil then
    FinishUnsubscribe(lbopFailed, LazBleErrorInvalidState, 'No native subscription token')
  else FNativeUnsubscribeOperation.OnCompleted := @UnsubscribeCompleted;
end;

procedure TBleSubscription.FinishUnsubscribe(const AState: TLazBleOperationState;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  if AState = lbopFailed then SetState(lbsubFailed) else SetState(lbsubInactive);
  TUnsubscribeOperation(FUnsubscribeObject).Finish(AState, AErrorCode, AErrorMessage);
end;

procedure TBleSubscription.UnsubscribeCompleted(Sender: TObject);
var
  Operation: IBleGattOperation;
begin
  LazBleRequireMainThread;
  Operation := FNativeUnsubscribeOperation;
  if Operation = nil then Exit;
  Operation.OnCompleted := nil;
  FinishUnsubscribe(Operation.State, Operation.ErrorCode, Operation.ErrorMessage);
end;

procedure TBleSubscription.HandleBackendEvent(const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  if (AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration) then Exit;
  if FClosing then Exit;
  if (AEvent.OperationId = FOperationId) then
    case AEvent.Kind of
      lbekSubscribed:
        begin
          FSubscriptionId := AEvent.SubscriptionId;
          if FState = lbsubPending then SetState(lbsubActive);
        end;
      lbekOperationSucceeded:
        if FState = lbsubUnsubscribing then StartNativeUnsubscribe;
      lbekOperationFailed, lbekOperationCancelled:
        if FState = lbsubUnsubscribing then
        begin
          if FSubscriptionId <> InvalidBleSubscriptionId then StartNativeUnsubscribe
          else FinishUnsubscribe(lbopSucceeded);
        end
        else if FState in [lbsubPending, lbsubActive] then
        begin
          FErrorCode := AEvent.ErrorCode;
          FErrorMessage := AEvent.ErrorMessage;
          if FErrorMessage = '' then FErrorMessage := 'BLE subscription did not complete';
          SetState(lbsubFailed);
        end;
    end;
  if (FState = lbsubActive) and (AEvent.Kind = lbekNotification) and
    (AEvent.SubscriptionId = FSubscriptionId) and Assigned(FOnData) then
    FOnData(Self, AEvent.Value);
end;

function TBleSubscription.CleanupPending: Boolean;
begin
  Result := (FUnsubscribeOperation <> nil) and (FUnsubscribeOperation.State = lbopPending);
end;

procedure TBleSubscription.DetachCallbacks;
begin
  FOnData := nil; FOnStateChanged := nil;
  if FUnsubscribeOperation <> nil then FUnsubscribeOperation.OnCompleted := nil;
  if FNativeUnsubscribeOperation <> nil then FNativeUnsubscribeOperation.OnCompleted := nil;
end;

procedure TBleSubscription.Invalidate(const AForce: Boolean);
begin
  LazBleRequireMainThread;
  FOnData := nil;
  DetachOwner;
  if CleanupPending and (AForce or (FNativeUnsubscribeOperation = nil)) then
  begin
    if FNativeUnsubscribeOperation <> nil then FNativeUnsubscribeOperation.OnCompleted := nil;
    if FClosing then FinishUnsubscribe(lbopCancelled, 0, 'Unsubscribe interrupted by shutdown')
    else FinishUnsubscribe(lbopCancelled, LazBleErrorDeviceDisconnected,
      'Disconnected before unsubscribe was submitted');
  end;
  { A submitted Unsubscribe keeps its callback and token context alive until
    its real terminal result. No value delivery survives the connection. }
  if FState <> lbsubFailed then SetState(lbsubInactive);
  FOnStateChanged := nil;
end;

procedure TBleSubscription.BeginShutdown;
begin
  LazBleRequireMainThread;
  FClosing := True;
  FOnData := nil;
  FOnStateChanged := nil;
end;

procedure TBleSubscription.DetachOwner;
begin LazBleRequireMainThread; FUnsubscribe := nil; end;
function TBleSubscription.GetOperationId: TBleOperationId;
begin Result := FOperationId; end;
function TBleSubscription.GetSubscriptionId: TBleSubscriptionId;
begin Result := FSubscriptionId; end;
function TBleSubscription.GetGeneration: QWord;
begin Result := FGeneration; end;

end.
