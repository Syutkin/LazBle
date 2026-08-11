unit LazBleNus;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription,
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
    FCallbackLock: TRTLCriticalSection;
    FChannel: TBleByteChannel;
    FOnData: TNusDataEvent;
    function GetOnData: TNusDataEvent;
    procedure SetOnData(const AHandler: TNusDataEvent);
    procedure ChannelDataReceived(Sender: TObject; const AValue: TBytes);
    procedure SubscriptionStateChanged(Sender: TObject;
      const AState: TLazBleSubscriptionState);
    procedure MarkSubscriptionError;
  protected
    procedure DoBind; override;
    procedure DoAttach; override;
    procedure DoDetach; override;
    procedure RefreshState; override;
    property Channel: TBleByteChannel read FChannel;
  public
    constructor Create;
    destructor Destroy; override;
    function SendAsync(const AValue: TBytes): IBleGattOperation;
    property OnData: TNusDataEvent read GetOnData write SetOnData;
  end;

implementation

type
  TBleGattOperationAccess = class(TBleGattOperation)
  public
    constructor CreateTerminal(const AErrorMessage: string);
  end;

constructor TBleGattOperationAccess.CreateTerminal(
  const AErrorMessage: string);
begin
  inherited CreateCompleted(lbckWrite, lbopFailed, AErrorMessage);
end;

constructor TNusProfile.Create;
begin
  inherited Create;
  InitCriticalSection(FCallbackLock);
end;

procedure TNusProfile.DoBind;
begin
  FChannel := TBleByteChannel.Create(Session, NusServiceUuid,
    NusRxCharacteristicUuid, NusTxCharacteristicUuid, lbwmCommand);
  FChannel.OnData := @ChannelDataReceived;
end;

destructor TNusProfile.Destroy;
begin
  Detach;
  SetOnData(nil);
  if Assigned(FChannel) then
    FChannel.OnData := nil;
  FChannel.Free;
  FChannel := nil;
  DoneCriticalSection(FCallbackLock);
  inherited Destroy;
end;

function TNusProfile.GetOnData: TNusDataEvent;
begin
  EnterCriticalSection(FCallbackLock);
  try
    Result := FOnData;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TNusProfile.SetOnData(const AHandler: TNusDataEvent);
begin
  EnterCriticalSection(FCallbackLock);
  try
    FOnData := AHandler;
  finally
    LeaveCriticalSection(FCallbackLock);
  end;
end;

procedure TNusProfile.ChannelDataReceived(Sender: TObject;
  const AValue: TBytes);
var
  Handler: TNusDataEvent;
begin
  Handler := GetOnData;
  if Assigned(Handler) then
    Handler(Self, DeviceId, AValue);
end;

procedure TNusProfile.SubscriptionStateChanged(Sender: TObject;
  const AState: TLazBleSubscriptionState);
begin
  RefreshState;
end;

procedure TNusProfile.DoAttach;
var
  Characteristic: TLazBleGattCharacteristic;
begin
  if not Assigned(FChannel) then
  begin
    MarkError('NUS profile is not bound to a client');
    Exit;
  end;
  if not Session.HasService(NusServiceUuid) then
  begin
    MarkError('NUS service was not found', LazBleErrorGattNotFound);
    Exit;
  end;
  if not Session.TryGetCharacteristic(NusServiceUuid,
    NusRxCharacteristicUuid, Characteristic) then
  begin
    MarkError('NUS RX characteristic was not found',
      LazBleErrorGattNotFound);
    Exit;
  end;
  if not (lbgcpWriteCommand in Characteristic.Properties) then
  begin
    MarkError('NUS RX characteristic does not support write commands',
      LazBleErrorGattPropertyNotSupported);
    Exit;
  end;
  if not Session.TryGetCharacteristic(NusServiceUuid,
    NusTxCharacteristicUuid, Characteristic) then
  begin
    MarkError('NUS TX characteristic was not found',
      LazBleErrorGattNotFound);
    Exit;
  end;
  if not (lbgcpNotify in Characteristic.Properties) then
  begin
    MarkError('NUS TX characteristic does not support notifications',
      LazBleErrorGattPropertyNotSupported);
    Exit;
  end;
  FChannel.Attach;
  if Assigned(FChannel.Subscription) then
    FChannel.Subscription.OnStateChanged := @SubscriptionStateChanged;
  if FChannel.State = lbchsError then
    MarkSubscriptionError;
end;

procedure TNusProfile.MarkSubscriptionError;
var
  Subscription: IBleSubscription;
begin
  Subscription := FChannel.Subscription;
  if Assigned(Subscription) and (Subscription.ErrorMessage <> '') then
    MarkError(Subscription.ErrorMessage, Subscription.ErrorCode)
  else
    MarkError('Could not subscribe to NUS TX notifications');
end;

procedure TNusProfile.DoDetach;
begin
  if not Assigned(FChannel) then
    Exit;
  if Assigned(FChannel.Subscription) then
    FChannel.Subscription.OnStateChanged := nil;
  FChannel.Detach;
end;

procedure TNusProfile.RefreshState;
begin
  if not Assigned(FChannel) or (CurrentState = lbgpsError) then
    Exit;
  case FChannel.State of
    lbchsReady:
      MarkReady;
    lbchsError:
      MarkSubscriptionError;
    lbchsDetached:
      MarkError('NUS TX subscription is no longer active');
  end;
end;

function TNusProfile.SendAsync(const AValue: TBytes): IBleGattOperation;
begin
  if Assigned(FChannel) then
    Result := FChannel.SendAsync(AValue)
  else
    Result := TBleGattOperationAccess.CreateTerminal(
      'NUS profile is not bound to a client');
end;

end.
