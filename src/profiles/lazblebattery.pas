unit LazBleBattery;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
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

  TBleBatteryProfile = class(TBleGattProfile)
  private type
    TLazBleBatteryPhase = (
      lbbpDetached,
      lbbpReading,
      lbbpSubscribing
    );
  private
    FLevelLock: TRTLCriticalSection;
    FCallbackLock: TRTLCriticalSection;
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
    procedure SetProfileError(const AMessage: string);
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
    property LevelPercent: Integer read GetLevelPercent;
    property OnLevelChanged: TLazBleBatteryLevelEvent read GetOnLevelChanged
      write SetOnLevelChanged;
  end;

implementation

constructor TBleBatteryProfile.Create;
begin
  inherited Create;
  InitCriticalSection(FLevelLock);
  InitCriticalSection(FCallbackLock);
  FPhase := lbbpDetached;
  FLevelPercent := UnknownBatteryLevel;
end;

destructor TBleBatteryProfile.Destroy;
begin
  Detach;
  SetOnLevelChanged(nil);
  DoneCriticalSection(FCallbackLock);
  DoneCriticalSection(FLevelLock);
  inherited Destroy;
end;

function TBleBatteryProfile.GetLevelPercent: Integer;
begin
  EnterCriticalSection(FLevelLock);
  try
    Result := FLevelPercent;
  finally
    LeaveCriticalSection(FLevelLock);
  end;
end;

function TBleBatteryProfile.GetOnLevelChanged: TLazBleBatteryLevelEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnLevelChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleBatteryProfile.SetOnLevelChanged(
  const AHandler: TLazBleBatteryLevelEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnLevelChanged := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TBleBatteryProfile.SetProfileError(const AMessage: string);
begin
  MarkError(AMessage);
end;

function TBleBatteryProfile.AcceptLevel(const AValue: TBytes): Boolean;
var
  Handler: TLazBleBatteryLevelEvent;
  NewLevel: Integer;
begin
  Result := (Length(AValue) = 1) and (AValue[0] <= 100);
  if not Result then
  begin
    SetProfileError('Battery Level must be one byte in the range 0..100');
    Exit;
  end;

  NewLevel := AValue[0];
  EnterCriticalSection(FLevelLock);
  try
    if NewLevel = FLevelPercent then
      Exit;
    FLevelPercent := NewLevel;
  finally
    LeaveCriticalSection(FLevelLock);
  end;
  EnterCriticalSection(FCallbackLock);
  try
    Handler := FOnLevelChanged;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
  if Assigned(Handler) then
    Handler(Self, DeviceId, NewLevel);
end;

procedure TBleBatteryProfile.ReadCompleted(Sender: TObject);
begin
  if (FPhase <> lbbpReading) or
    (CurrentState <> lbgpsAttaching) then
    Exit;
  FReadOperation.OnCompleted := nil;

  if FReadOperation.State <> lbopSucceeded then
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
  if FReadOperation.State <> lbopPending then
    ReadCompleted(nil);
end;

procedure TBleBatteryProfile.DoDetach;
begin
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

  EnterCriticalSection(FLevelLock);
  try
    FLevelPercent := UnknownBatteryLevel;
  finally
    LeaveCriticalSection(FLevelLock);
  end;
  FPhase := lbbpDetached;
end;

end.
