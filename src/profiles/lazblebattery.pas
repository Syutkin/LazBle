unit LazBleBattery;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile;

const
  BatteryServiceUuid = '0000180F-0000-1000-8000-00805F9B34FB';
  BatteryLevelCharacteristicUuid = '00002A19-0000-1000-8000-00805F9B34FB';
  UnknownBatteryLevel = -1;

type
  TLazBleBatteryPhase = (
    lbbpDetached,
    lbbpReading,
    lbbpSubscribing
  );

  TLazBleBatteryLevelEvent = procedure(Sender: TObject;
    const ADeviceId: string; const ALevelPercent: Integer) of object;

  TBleBatteryProfile = class(TBleGattProfile)
  private
    FPhase: TLazBleBatteryPhase;
    FLevelPercent: Integer;
    FReadOperation: TBleGattOperation;
    FSubscription: TBleSubscription;
    FDetachOperation: TBleGattOperation;
    FOnLevelChanged: TLazBleBatteryLevelEvent;
    procedure ReadCompleted(Sender: TObject);
    procedure NotificationReceived(Sender: TObject; const AValue: TBytes);
    procedure SubscriptionStateChanged(Sender: TObject;
      const AState: TLazBleSubscriptionState);
    function AcceptLevel(const AValue: TBytes): Boolean;
    procedure SetProfileError(const AMessage: string);
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
    procedure RefreshState; override;
  public
    constructor Create;
    destructor Destroy; override;
    property LevelPercent: Integer read FLevelPercent;
    property ReadOperation: TBleGattOperation read FReadOperation;
    property Subscription: TBleSubscription read FSubscription;
    property DetachOperation: TBleGattOperation read FDetachOperation;
    property OnLevelChanged: TLazBleBatteryLevelEvent read FOnLevelChanged
      write FOnLevelChanged;
  end;

implementation

constructor TBleBatteryProfile.Create;
begin
  inherited Create;
  FPhase := lbbpDetached;
  FLevelPercent := UnknownBatteryLevel;
end;

destructor TBleBatteryProfile.Destroy;
begin
  Detach;
  inherited Destroy;
end;

procedure TBleBatteryProfile.SetProfileError(const AMessage: string);
begin
  MarkError(AMessage);
end;

function TBleBatteryProfile.AcceptLevel(const AValue: TBytes): Boolean;
var
  NewLevel: Integer;
begin
  Result := (Length(AValue) = 1) and (AValue[0] <= 100);
  if not Result then
  begin
    SetProfileError('Battery Level must be one byte in the range 0..100');
    Exit;
  end;

  NewLevel := AValue[0];
  if NewLevel = FLevelPercent then
    Exit;
  FLevelPercent := NewLevel;
  if Assigned(FOnLevelChanged) then
    FOnLevelChanged(Self, DeviceId, FLevelPercent);
end;

procedure TBleBatteryProfile.ReadCompleted(Sender: TObject);
begin
  if (Sender <> FReadOperation) or (FPhase <> lbbpReading) or
    (CurrentState <> lbgpsAttaching) then
    Exit;
  FReadOperation.OnCompleted := nil;

  if FReadOperation.State <> lbosSucceeded then
  begin
    SetProfileError('Could not read Battery Level');
    Exit;
  end;
  if not AcceptLevel(FReadOperation.Value) then
    Exit;

  FSubscription := Session.SubscribeAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FSubscription.OnData := @NotificationReceived;
  FSubscription.OnStateChanged := @SubscriptionStateChanged;
  if FSubscription.State = lbsubFailed then
    SetProfileError('Could not subscribe to Battery Level')
  else
    FPhase := lbbpSubscribing;
end;

procedure TBleBatteryProfile.NotificationReceived(Sender: TObject;
  const AValue: TBytes);
begin
  if Sender <> FSubscription then
    Exit;
  if AcceptLevel(AValue) then
    MarkReady;
end;

procedure TBleBatteryProfile.SubscriptionStateChanged(Sender: TObject;
  const AState: TLazBleSubscriptionState);
begin
  RefreshState;
end;

procedure TBleBatteryProfile.RefreshState;
begin
  if (FPhase = lbbpSubscribing) and Assigned(FSubscription) then
    case FSubscription.State of
      lbsubActive:
        MarkReady;
      lbsubFailed:
        SetProfileError('Could not subscribe to Battery Level');
      lbsubInactive:
        SetProfileError('Battery Level subscription is no longer active');
    end;
end;

procedure TBleBatteryProfile.DoAttach;
begin
  FDetachOperation := nil;
  FReadOperation := nil;
  FSubscription := nil;
  FPhase := lbbpReading;
  FReadOperation := Session.ReadAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FReadOperation.OnCompleted := @ReadCompleted;
  if FReadOperation.State <> lbosPending then
    ReadCompleted(FReadOperation);
end;

procedure TBleBatteryProfile.DoDetach;
begin
  if Assigned(FReadOperation) and
    (FReadOperation.State = lbosPending) then
  begin
    FReadOperation.OnCompleted := nil;
    Session.CancelOperation(FReadOperation);
  end;

  if Assigned(FSubscription) then
  begin
    FSubscription.OnData := nil;
    FSubscription.OnStateChanged := nil;
    if FSubscription.State = lbsubPending then
      Session.CancelSubscription(FSubscription)
    else
      FDetachOperation := FSubscription.Unsubscribe;
  end;

  FLevelPercent := UnknownBatteryLevel;
  FPhase := lbbpDetached;
end;

end.
