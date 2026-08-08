unit LazBleNus;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleByteChannel;

const
  NusServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  NusRxCharacteristicUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  NusTxCharacteristicUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

type
  TNusDataEvent = procedure(Sender: TObject; const ADeviceId: string;
    const AValue: TBytes) of object;

  TNusProfile = class
  private
    FDeviceId: string;
    FChannel: TBleByteChannel;
    FOnData: TNusDataEvent;
    procedure ChannelDataReceived(Sender: TObject; const AValue: TBytes);
    function GetReady: Boolean;
    function GetState: TLazBleByteChannelState;
  public
    constructor Create(const ASession: TBleGattSession);
    destructor Destroy; override;
    function Attach: TBleSubscription;
    function Detach: TBleGattOperation;
    function SendAsync(const AValue: TBytes): TBleGattOperation;
    property Channel: TBleByteChannel read FChannel;
    property Ready: Boolean read GetReady;
    property State: TLazBleByteChannelState read GetState;
    property OnData: TNusDataEvent read FOnData write FOnData;
  end;

implementation

constructor TNusProfile.Create(const ASession: TBleGattSession);
begin
  inherited Create;
  if not Assigned(ASession) then
    raise EArgumentNilException.Create('ASession');
  FDeviceId := ASession.DeviceId;
  FChannel := TBleByteChannel.Create(ASession, NusServiceUuid,
    NusRxCharacteristicUuid, NusTxCharacteristicUuid, lbwmCommand);
  FChannel.OnData := @ChannelDataReceived;
end;

destructor TNusProfile.Destroy;
begin
  FChannel.OnData := nil;
  FChannel.Free;
  FChannel := nil;
  inherited Destroy;
end;

procedure TNusProfile.ChannelDataReceived(Sender: TObject;
  const AValue: TBytes);
begin
  if Assigned(FOnData) then
    FOnData(Self, FDeviceId, AValue);
end;

function TNusProfile.GetReady: Boolean;
begin
  Result := FChannel.Ready;
end;

function TNusProfile.GetState: TLazBleByteChannelState;
begin
  Result := FChannel.State;
end;

function TNusProfile.Attach: TBleSubscription;
begin
  Result := FChannel.Attach;
end;

function TNusProfile.Detach: TBleGattOperation;
begin
  Result := FChannel.Detach;
end;

function TNusProfile.SendAsync(const AValue: TBytes): TBleGattOperation;
begin
  Result := FChannel.SendAsync(AValue);
end;

end.
