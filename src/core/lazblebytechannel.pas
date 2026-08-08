unit LazBleByteChannel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession;

type
  TLazBleByteChannelState = (
    lbchsDetached,
    lbchsSubscribing,
    lbchsReady,
    lbchsUnsubscribing,
    lbchsError
  );

  TLazBleByteChannelDataEvent = procedure(Sender: TObject;
    const AValue: TBytes) of object;

  TBleByteChannel = class
  private
    FSession: TBleGattSession;
    FServiceUuid: string;
    FWriteCharacteristicUuid: string;
    FNotifyCharacteristicUuid: string;
    FWriteMode: TLazBleWriteMode;
    FSubscription: TBleSubscription;
    FDetachOperation: TBleGattOperation;
    FOnData: TLazBleByteChannelDataEvent;
    function GetState: TLazBleByteChannelState;
    function GetReady: Boolean;
    procedure SubscriptionDataReceived(Sender: TObject;
      const AValue: TBytes);
  public
    constructor Create(const ASession: TBleGattSession;
      const AServiceUuid, AWriteCharacteristicUuid,
      ANotifyCharacteristicUuid: string;
      const AWriteMode: TLazBleWriteMode);
    destructor Destroy; override;
    function Attach: TBleSubscription;
    function Detach: TBleGattOperation;
    function SendAsync(const AValue: TBytes): TBleGattOperation;
    property ServiceUuid: string read FServiceUuid;
    property WriteCharacteristicUuid: string read FWriteCharacteristicUuid;
    property NotifyCharacteristicUuid: string read FNotifyCharacteristicUuid;
    property WriteMode: TLazBleWriteMode read FWriteMode;
    property Subscription: TBleSubscription read FSubscription;
    property State: TLazBleByteChannelState read GetState;
    property Ready: Boolean read GetReady;
    property OnData: TLazBleByteChannelDataEvent read FOnData write FOnData;
  end;

implementation

constructor TBleByteChannel.Create(const ASession: TBleGattSession;
  const AServiceUuid, AWriteCharacteristicUuid,
  ANotifyCharacteristicUuid: string; const AWriteMode: TLazBleWriteMode);
begin
  inherited Create;
  FSession := ASession;
  FServiceUuid := AServiceUuid;
  FWriteCharacteristicUuid := AWriteCharacteristicUuid;
  FNotifyCharacteristicUuid := ANotifyCharacteristicUuid;
  FWriteMode := AWriteMode;
end;

destructor TBleByteChannel.Destroy;
begin
  Detach;
  FSession := nil;
  inherited Destroy;
end;

function TBleByteChannel.GetState: TLazBleByteChannelState;
begin
  if not Assigned(FSubscription) then
    Exit(lbchsDetached);
  case FSubscription.State of
    lbsubPending:
      Result := lbchsSubscribing;
    lbsubActive:
      Result := lbchsReady;
    lbsubUnsubscribing:
      Result := lbchsUnsubscribing;
    lbsubFailed:
      Result := lbchsError;
    else
      Result := lbchsDetached;
  end;
end;

function TBleByteChannel.GetReady: Boolean;
begin
  Result := GetState = lbchsReady;
end;

procedure TBleByteChannel.SubscriptionDataReceived(Sender: TObject;
  const AValue: TBytes);
begin
  if Assigned(FOnData) then
    FOnData(Self, AValue);
end;

function TBleByteChannel.Attach: TBleSubscription;
begin
  if Assigned(FSubscription) and
    (FSubscription.State in [lbsubPending, lbsubActive,
      lbsubUnsubscribing]) then
    Exit(FSubscription);

  FDetachOperation := nil;
  if not Assigned(FSession) then
    Exit(nil);
  FSubscription := FSession.SubscribeAsync(FServiceUuid,
    FNotifyCharacteristicUuid);
  FSubscription.OnData := @SubscriptionDataReceived;
  Result := FSubscription;
end;

function TBleByteChannel.Detach: TBleGattOperation;
begin
  if Assigned(FDetachOperation) then
    Exit(FDetachOperation);
  if not Assigned(FSubscription) then
    Exit(nil);

  FSubscription.OnData := nil;
  FDetachOperation := FSubscription.Unsubscribe;
  Result := FDetachOperation;
end;

function TBleByteChannel.SendAsync(const AValue: TBytes): TBleGattOperation;
begin
  if not Ready or not Assigned(FSession) then
    Exit(nil);
  Result := FSession.WriteAsync(FServiceUuid, FWriteCharacteristicUuid,
    AValue, FWriteMode);
end;

end.
