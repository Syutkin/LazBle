unit LazBleGattSubscription;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
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
  TBleSubscription = class;
  TLazBleUnsubscribe = function(
    const ASubscription: TBleSubscription): TBleGattOperation of object;

  TBleSubscription = class
  private
    FOperationId: TBleOperationId;
    FSubscriptionId: TBleSubscriptionId;
    FGeneration: QWord;
    FState: TLazBleSubscriptionState;
    FUnsubscribe: TLazBleUnsubscribe;
    FUnsubscribeOperation: TBleGattOperation;
    FOnData: TLazBleDataEvent;
    FOnStateChanged: TLazBleSubscriptionStateChangedEvent;
    procedure SetState(const AState: TLazBleSubscriptionState);
  public
    constructor Create(const AOperationId: TBleOperationId;
      const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
    function Unsubscribe: TBleGattOperation;
    procedure BeginUnsubscribe(const AOperation: TBleGattOperation);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure Invalidate;
    property OperationId: TBleOperationId read FOperationId;
    property SubscriptionId: TBleSubscriptionId read FSubscriptionId;
    property Generation: QWord read FGeneration;
    property State: TLazBleSubscriptionState read FState;
    property OnData: TLazBleDataEvent read FOnData write FOnData;
    property OnStateChanged: TLazBleSubscriptionStateChangedEvent
      read FOnStateChanged write FOnStateChanged;
  end;

implementation

procedure TBleSubscription.SetState(const AState: TLazBleSubscriptionState);
begin
  if FState = AState then
    Exit;
  FState := AState;
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
end;

constructor TBleSubscription.Create(const AOperationId: TBleOperationId;
  const AGeneration: QWord; const AUnsubscribe: TLazBleUnsubscribe);
begin
  inherited Create;
  FOperationId := AOperationId;
  FGeneration := AGeneration;
  FUnsubscribe := AUnsubscribe;
  if AOperationId = InvalidBleOperationId then
    FState := lbsubFailed
  else
    FState := lbsubPending;
end;

function TBleSubscription.Unsubscribe: TBleGattOperation;
begin
  if Assigned(FUnsubscribeOperation) or
    (FState in [lbsubInactive, lbsubFailed]) then
    Exit(FUnsubscribeOperation);
  if Assigned(FUnsubscribe) then
    Result := FUnsubscribe(Self)
  else
    Result := nil;
end;

procedure TBleSubscription.BeginUnsubscribe(
  const AOperation: TBleGattOperation);
begin
  FUnsubscribeOperation := AOperation;
  if Assigned(AOperation) then
  begin
    if AOperation.State = lbosFailed then
      SetState(lbsubFailed)
    else
      SetState(lbsubUnsubscribing);
  end;
end;

procedure TBleSubscription.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if (AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration) then
    Exit;

  if (AEvent.OperationId = FOperationId) and
    (FState in [lbsubPending, lbsubActive]) then
    case AEvent.Kind of
      lbekSubscribed:
        begin
          FSubscriptionId := AEvent.SubscriptionId;
          SetState(lbsubActive);
        end;
      lbekOperationFailed,
      lbekOperationCancelled:
        SetState(lbsubFailed);
    end;

  if (FState = lbsubUnsubscribing) and Assigned(FUnsubscribeOperation) and
    (AEvent.OperationId = FUnsubscribeOperation.OperationId) and
    LazBleBackendEventIsTerminal(AEvent) then
  begin
    if AEvent.Kind = lbekOperationFailed then
      SetState(lbsubFailed)
    else
      SetState(lbsubInactive);
  end;

  if (FState = lbsubActive) and (AEvent.Kind = lbekNotification) and
    (AEvent.SubscriptionId = FSubscriptionId) and Assigned(FOnData) then
    FOnData(Self, AEvent.Value);
end;

procedure TBleSubscription.Invalidate;
begin
  FUnsubscribe := nil;
  FOnData := nil;
  SetState(lbsubInactive);
  FOnStateChanged := nil;
end;

end.
