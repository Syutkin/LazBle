unit LazBleNus;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleByteChannel;

const
  NusServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  NusRxCharacteristicUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  NusTxCharacteristicUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

type
  TNusDataEvent = procedure(Sender: TObject; const ADeviceId: string;
    const AValue: TBytes) of object;

  TNusProfile = class(TBleGattProfile)
  private
    FChannel: TBleByteChannel;
    FOnData: TNusDataEvent;
    procedure ChannelDataReceived(Sender: TObject; const AValue: TBytes);
    procedure SubscriptionStateChanged(Sender: TObject;
      const AState: TLazBleSubscriptionState);
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
    procedure RefreshState; override;
  public
    constructor Create(const ASession: TBleGattSession);
    destructor Destroy; override;
    function SendAsync(const AValue: TBytes): TBleGattOperation;
    property Channel: TBleByteChannel read FChannel;
    property OnData: TNusDataEvent read FOnData write FOnData;
  end;

implementation

constructor TNusProfile.Create(const ASession: TBleGattSession);
begin
  inherited Create(ASession);
  FChannel := TBleByteChannel.Create(ASession, NusServiceUuid,
    NusRxCharacteristicUuid, NusTxCharacteristicUuid, lbwmCommand);
  FChannel.OnData := @ChannelDataReceived;
end;

destructor TNusProfile.Destroy;
begin
  Detach;
  FChannel.OnData := nil;
  FChannel.Free;
  FChannel := nil;
  inherited Destroy;
end;

procedure TNusProfile.ChannelDataReceived(Sender: TObject;
  const AValue: TBytes);
begin
  if Assigned(FOnData) then
    FOnData(Self, DeviceId, AValue);
end;

procedure TNusProfile.SubscriptionStateChanged(Sender: TObject;
  const AState: TLazBleSubscriptionState);
begin
  RefreshState;
end;

procedure TNusProfile.DoAttach;
begin
  FChannel.Attach;
  if Assigned(FChannel.Subscription) then
    FChannel.Subscription.OnStateChanged := @SubscriptionStateChanged;
  if FChannel.State = lbchsError then
    MarkError('Could not subscribe to NUS TX notifications');
end;

procedure TNusProfile.DoDetach;
begin
  if Assigned(FChannel.Subscription) then
    FChannel.Subscription.OnStateChanged := nil;
  FChannel.Detach;
end;

procedure TNusProfile.RefreshState;
begin
  case FChannel.State of
    lbchsReady:
      MarkReady;
    lbchsError:
      MarkError('Could not subscribe to NUS TX notifications');
    lbchsDetached:
      MarkError('NUS TX subscription is no longer active');
  end;
end;

function TNusProfile.SendAsync(const AValue: TBytes): TBleGattOperation;
begin
  Result := FChannel.SendAsync(AValue);
end;

end.
