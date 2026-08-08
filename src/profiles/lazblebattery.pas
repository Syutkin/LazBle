unit LazBleBattery;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession;

const
  BatteryServiceUuid = '0000180F-0000-1000-8000-00805F9B34FB';
  BatteryLevelCharacteristicUuid = '00002A19-0000-1000-8000-00805F9B34FB';
  UnknownBatteryLevel = -1;

type
  TLazBleBatteryState = (
    lbbsDetached,
    lbbsReading,
    lbbsSubscribing,
    lbbsReady,
    lbbsError
  );

  TLazBleBatteryLevelEvent = procedure(Sender: TObject;
    const ADeviceId: string; const ALevelPercent: Integer) of object;

  TBleBatteryProfile = class
  private
    FSession: TBleGattSession;
    FDeviceId: string;
    FState: TLazBleBatteryState;
    FLevelPercent: Integer;
    FReadOperation: TBleGattOperation;
    FSubscription: TBleSubscription;
    FDetachOperation: TBleGattOperation;
    FErrorMessage: string;
    FOnLevelChanged: TLazBleBatteryLevelEvent;
    procedure ReadCompleted(Sender: TObject);
    procedure NotificationReceived(Sender: TObject; const AValue: TBytes);
    function AcceptLevel(const AValue: TBytes): Boolean;
    procedure SetProfileError(const AMessage: string);
    function GetState: TLazBleBatteryState;
    function GetReady: Boolean;
  public
    constructor Create(const ASession: TBleGattSession);
    destructor Destroy; override;
    function Attach: TBleGattOperation;
    function Detach: TBleGattOperation;
    property DeviceId: string read FDeviceId;
    property LevelPercent: Integer read FLevelPercent;
    property ReadOperation: TBleGattOperation read FReadOperation;
    property Subscription: TBleSubscription read FSubscription;
    property State: TLazBleBatteryState read GetState;
    property Ready: Boolean read GetReady;
    property ErrorMessage: string read FErrorMessage;
    property OnLevelChanged: TLazBleBatteryLevelEvent read FOnLevelChanged
      write FOnLevelChanged;
  end;

implementation

constructor TBleBatteryProfile.Create(const ASession: TBleGattSession);
begin
  inherited Create;
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FSession := ASession;
  FDeviceId := ASession.DeviceId;
  FState := lbbsDetached;
  FLevelPercent := UnknownBatteryLevel;
end;

destructor TBleBatteryProfile.Destroy;
begin
  Detach;
  FSession := nil;
  inherited Destroy;
end;

procedure TBleBatteryProfile.SetProfileError(const AMessage: string);
begin
  FState := lbbsError;
  FErrorMessage := AMessage;
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
    FOnLevelChanged(Self, FDeviceId, FLevelPercent);
end;

procedure TBleBatteryProfile.ReadCompleted(Sender: TObject);
begin
  if (Sender <> FReadOperation) or (FState <> lbbsReading) then
    Exit;
  FReadOperation.OnCompleted := nil;

  if FReadOperation.State <> lbosSucceeded then
  begin
    SetProfileError('Could not read Battery Level');
    Exit;
  end;
  if not AcceptLevel(FReadOperation.Value) then
    Exit;

  FSubscription := FSession.SubscribeAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FSubscription.OnData := @NotificationReceived;
  if FSubscription.State = lbsubFailed then
    SetProfileError('Could not subscribe to Battery Level')
  else
    FState := lbbsSubscribing;
end;

procedure TBleBatteryProfile.NotificationReceived(Sender: TObject;
  const AValue: TBytes);
begin
  if Sender <> FSubscription then
    Exit;
  if AcceptLevel(AValue) then
    FState := lbbsReady;
end;

function TBleBatteryProfile.GetState: TLazBleBatteryState;
begin
  Result := FState;
  if (FState = lbbsSubscribing) and Assigned(FSubscription) then
    case FSubscription.State of
      lbsubActive:
        Result := lbbsReady;
      lbsubFailed:
        begin
          SetProfileError('Could not subscribe to Battery Level');
          Result := FState;
        end;
    end;
end;

function TBleBatteryProfile.GetReady: Boolean;
begin
  Result := GetState = lbbsReady;
end;

function TBleBatteryProfile.Attach: TBleGattOperation;
begin
  if FState <> lbbsDetached then
    Exit(FReadOperation);

  FErrorMessage := '';
  FDetachOperation := nil;
  FReadOperation := nil;
  FSubscription := nil;
  FState := lbbsReading;
  FReadOperation := FSession.ReadAsync(BatteryServiceUuid,
    BatteryLevelCharacteristicUuid);
  FReadOperation.OnCompleted := @ReadCompleted;
  if FReadOperation.State <> lbosPending then
    ReadCompleted(FReadOperation);
  Result := FReadOperation;
end;

function TBleBatteryProfile.Detach: TBleGattOperation;
begin
  if FState = lbbsDetached then
    Exit(FDetachOperation);

  if Assigned(FReadOperation) and
    (FReadOperation.State = lbosPending) then
  begin
    FReadOperation.OnCompleted := nil;
    FSession.CancelOperation(FReadOperation);
  end;

  if Assigned(FSubscription) then
  begin
    FSubscription.OnData := nil;
    if FSubscription.State = lbsubPending then
      FSession.CancelSubscription(FSubscription)
    else
      FDetachOperation := FSubscription.Unsubscribe;
  end;

  FLevelPercent := UnknownBatteryLevel;
  FErrorMessage := '';
  FState := lbbsDetached;
  Result := FDetachOperation;
end;

end.
