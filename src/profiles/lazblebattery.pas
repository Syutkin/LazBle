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
      lbbpSubscribing
    );
  private
    FPhase: TLazBleBatteryPhase;
    FLevelPercent: Integer;
    FReadOperation: IBleGattOperation;
    FSubscription: IBleSubscription;
    FDetachOperation: IBleGattOperation;
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
    { Last valid level (0..100), or UnknownBatteryLevel before a reading. }
    property LevelPercent: Integer read GetLevelPercent;
    property OnLevelChanged: TLazBleBatteryLevelEvent read GetOnLevelChanged
      write SetOnLevelChanged;
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
begin
  LazBleRequireMainThread;
  if (FPhase <> lbbpReading) or
    (CurrentState <> lbgpsAttaching) then
    Exit;
  FReadOperation.OnCompleted := nil;

  if FReadOperation.State <> lbopSucceeded then
  begin
    SetProfileError('Could not read Battery Level', FReadOperation.ErrorCode);
    Exit;
  end;
  if not AcceptLevel(FReadOperation.Value) then
    Exit;

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
  if FReadOperation.State <> lbopPending then
    ReadCompleted(nil);
end;

procedure TBleBatteryProfile.DoDetach;
begin
  LazBleRequireMainThread;
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
  FPhase := lbbpDetached;
end;

end.
