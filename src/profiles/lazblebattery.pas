unit LazBleBattery;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile;

const
  BatteryServiceUuid = '0000180F-0000-1000-8000-00805F9B34FB';
  BatteryLevelCharacteristicUuid = '00002A19-0000-1000-8000-00805F9B34FB';
  UnknownBatteryLevel = -1;

type
  TLazBleBatteryLevelEvent = procedure(Sender: TObject;
    const ADeviceId: string; const ALevelPercent: Integer) of object;

  { Battery Service profile. It reads the initial level and then subscribes
    to Battery Level notifications when attachment succeeds. }
  TBleBatteryProfile = class(TBleGattProfile)
  private type
    TLazBleBatteryPhase = (
      lbbpDetached,
      lbbpReading,
      lbbpSubscribing,
      lbbpReady,
      lbbpRefreshing
    );
  private
    FPhase: TLazBleBatteryPhase;
    FLevelPercent: Integer;
    FReadOperation: IBleGattOperation;
    FSubscription: IBleSubscription;
    FDetachOperation: IBleGattOperation;
    FRefreshOperation: IBleOperation;
    FRefreshObject: TBleOperation;
    FOnLevelChanged: TLazBleBatteryLevelEvent;
    procedure ReadCompleted(Sender: TObject);
    procedure NotificationReceived(Sender: TObject; const AValue: TBytes);
    procedure SubscriptionStateChanged(Sender: TObject;
      const AState: TLazBleSubscriptionState);
    function AcceptLevel(const AValue: TBytes): Boolean;
    procedure SetProfileError(const AMessage: string;
      const AErrorCode: Integer = LazBleErrorInvalidState);
    function GetLevelPercent: Integer;
    function GetOnLevelChanged: TLazBleBatteryLevelEvent;
    procedure SetOnLevelChanged(const AHandler: TLazBleBatteryLevelEvent);
    procedure RefreshCancelled(Sender: TObject);
    procedure FinishRefresh(const AState: TLazBleOperationState;
      const ACode: Integer = 0; const AMessage: string = '');
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
    procedure RefreshState; override;
    property ReadOperation: IBleGattOperation read FReadOperation;
    property Subscription: IBleSubscription read FSubscription;
    property DetachOperation: IBleGattOperation read FDetachOperation;
  public
    constructor Create;
    destructor Destroy; override;
    function RefreshAsync: IBleOperation;
    { Last valid level (0..100), or UnknownBatteryLevel before a reading. }
    property LevelPercent: Integer read GetLevelPercent;
    property OnLevelChanged: TLazBleBatteryLevelEvent read GetOnLevelChanged
      write SetOnLevelChanged;
  end;

implementation

type
  TBatteryRefreshOperation = class(TBleOperation)
  public
    constructor Create(const ACancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const ACode: Integer; const AMessage: string);
  end;

constructor TBatteryRefreshOperation.Create(const ACancel: TLazBleOperationCancelEvent);
begin
  inherited Create(ACancel);
end;

procedure TBatteryRefreshOperation.Finish(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
begin
  Complete(AState, ACode, AMessage);
end;

function TBleBatteryProfile.RefreshAsync: IBleOperation;
var
  Operation: TBatteryRefreshOperation;
begin
  LazBleRequireMainThread;
  Operation := TBatteryRefreshOperation.Create(@RefreshCancelled);
  Result := Operation;
  if (CurrentState <> lbgpsReady) or Assigned(FRefreshOperation) or
    (FPhase = lbbpDetached) then
  begin
    Operation.Finish(lbopFailed, LazBleErrorInvalidState,
      'Battery profile is not ready or a refresh is already pending');
    Exit;
  end;
  FRefreshOperation := Result;
  FRefreshObject := Operation;
  FPhase := lbbpRefreshing;
  FReadOperation := Session.ReadAsync(BatteryServiceUuid, BatteryLevelCharacteristicUuid);
  FReadOperation.OnCompleted := @ReadCompleted;
end;

procedure TBleBatteryProfile.RefreshCancelled(Sender: TObject);
begin
  if Assigned(FReadOperation) then FReadOperation.Cancel;
end;

procedure TBleBatteryProfile.FinishRefresh(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
var
  KeepAlive: IBleOperation;
  Operation: TBatteryRefreshOperation;
begin
  if not Assigned(FRefreshOperation) then Exit;
  KeepAlive := FRefreshOperation;
  Operation := TBatteryRefreshOperation(FRefreshObject);
  FRefreshOperation := nil;
  FRefreshObject := nil;
  if FPhase = lbbpRefreshing then FPhase := lbbpReady;
  Operation.Finish(AState, ACode, AMessage);
end;

constructor TBleBatteryProfile.Create;
begin
  inherited Create;
  FPhase := lbbpDetached;
  FLevelPercent := UnknownBatteryLevel;
end;

destructor TBleBatteryProfile.Destroy;
begin
  Detach;
  SetOnLevelChanged(nil);
  inherited Destroy;
end;

function TBleBatteryProfile.GetLevelPercent: Integer;
begin
  LazBleRequireMainThread;
  Result := FLevelPercent;
end;

function TBleBatteryProfile.GetOnLevelChanged: TLazBleBatteryLevelEvent;
begin
  LazBleRequireMainThread;
  Result := FOnLevelChanged;
end;

procedure TBleBatteryProfile.SetOnLevelChanged(
  const AHandler: TLazBleBatteryLevelEvent);
begin
  LazBleRequireMainThread;
  FOnLevelChanged := AHandler;
end;

procedure TBleBatteryProfile.SetProfileError(const AMessage: string;
  const AErrorCode: Integer);
begin
  LazBleRequireMainThread;
  MarkError(AMessage, AErrorCode);
end;

function TBleBatteryProfile.AcceptLevel(const AValue: TBytes): Boolean;
var
  Handler: TLazBleBatteryLevelEvent;
  NewLevel: Integer;
begin
  LazBleRequireMainThread;
  Result := (Length(AValue) = 1) and (AValue[0] <= 100);
  if not Result then
  begin
    SetProfileError('Battery Level must be one byte in the range 0..100',
      LazBleErrorInvalidProfileData);
    Exit;
  end;

  NewLevel := AValue[0];
  if NewLevel = FLevelPercent then
    Exit;
  FLevelPercent := NewLevel;
  Handler := FOnLevelChanged;
  if Assigned(Handler) then
    Handler(Self, DeviceId, NewLevel);
end;

procedure TBleBatteryProfile.ReadCompleted(Sender: TObject);
var
  Characteristic: TLazBleGattCharacteristic;
  Operation: IBleGattOperation;
  Refreshing: Boolean;
begin
  LazBleRequireMainThread;
  Refreshing := FPhase = lbbpRefreshing;
  if not (FPhase in [lbbpReading, lbbpRefreshing]) then
    Exit;
  Operation := FReadOperation;
  Operation.OnCompleted := nil;

  if Operation.State <> lbopSucceeded then
  begin
    if Refreshing and (Operation.State = lbopCancelled) then
      FinishRefresh(lbopCancelled)
    else
    begin
      SetProfileError('Could not read Battery Level', Operation.ErrorCode);
      FinishRefresh(lbopFailed, Operation.ErrorCode, 'Could not read Battery Level');
    end;
    Exit;
  end;
  if not AcceptLevel(Operation.Value) then
  begin
    FinishRefresh(lbopFailed, LazBleErrorInvalidProfileData, 'Invalid Battery Level');
    Exit;
  end;
  if FPhase = lbbpDetached then Exit;
  if Refreshing then
  begin
    FinishRefresh(lbopSucceeded);
    Exit;
  end;

  if Session.TryGetCharacteristic(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid, Characteristic) and not Characteristic.CanNotify then
  begin
    FPhase := lbbpReady;
    MarkReady;
    Exit;
  end;

  FSubscription := Session.SubscribeAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FSubscription.OnData := @NotificationReceived;
  FSubscription.OnStateChanged := @SubscriptionStateChanged;
  if FSubscription.State = lbsubFailed then
    SetProfileError('Could not subscribe to Battery Level',
      FSubscription.ErrorCode)
  else
    FPhase := lbbpSubscribing;
end;

procedure TBleBatteryProfile.NotificationReceived(Sender: TObject;
  const AValue: TBytes);
begin
  LazBleRequireMainThread;
  if AcceptLevel(AValue) then
    MarkReady;
end;

procedure TBleBatteryProfile.SubscriptionStateChanged(Sender: TObject;
  const AState: TLazBleSubscriptionState);
begin
  LazBleRequireMainThread;
  RefreshState;
end;

procedure TBleBatteryProfile.RefreshState;
begin
  LazBleRequireMainThread;
  if (FPhase = lbbpSubscribing) and Assigned(FSubscription) then
    case FSubscription.State of
      lbsubActive:
        MarkReady;
      lbsubFailed:
        SetProfileError('Could not subscribe to Battery Level',
          FSubscription.ErrorCode);
      lbsubInactive:
        SetProfileError('Battery Level subscription is no longer active');
    end;
end;

procedure TBleBatteryProfile.DoAttach;
begin
  LazBleRequireMainThread;
  FDetachOperation := nil;
  FReadOperation := nil;
  FSubscription := nil;
  FPhase := lbbpReading;
  FReadOperation := Session.ReadAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FReadOperation.OnCompleted := @ReadCompleted;
end;

procedure TBleBatteryProfile.DoDetach;
begin
  LazBleRequireMainThread;
  FPhase := lbbpDetached;
  if Assigned(FReadOperation) and
    (FReadOperation.State = lbopPending) then
  begin
    FReadOperation.OnCompleted := nil;
    FReadOperation.Cancel;
  end;

  if Assigned(FSubscription) then
  begin
    FSubscription.OnData := nil;
    FSubscription.OnStateChanged := nil;
    FDetachOperation := FSubscription.Unsubscribe;
  end;

  FLevelPercent := UnknownBatteryLevel;
  FinishRefresh(lbopCancelled);
end;

end.
