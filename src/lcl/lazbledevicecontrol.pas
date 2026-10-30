unit LazBleDeviceControl;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  Controls,
  Forms,
  StdCtrls,
  ExtCtrls,
  LazBleTypes,
  LazBleClient,
  LazBleComponent,
  LazBleLclScan,
  LazBleDeviceSelectForm;

type
  TLazBleConnectionAction = (
    lbcaNone,
    lbcaConnect,
    lbcaDisconnect
  );

{ Presentation helpers accept nil clients and return localized UI text. }
function LazBleDeviceText(const AClient: TLazBleLclClient): string;
function LazBleStatusText(const AClient: TLazBleLclClient): string;
function LazBleCanSelectDevice(const AClient: TLazBleLclClient): Boolean;
function LazBleConnectionAction(
  const AClient: TLazBleLclClient): TLazBleConnectionAction;
function LazBleConnectionActionText(
  const AClient: TLazBleLclClient): string;

type
  { Design-time control for selecting a BLE device and toggling connection.
    Assign Client; the control does not own it. }
  TLazBleDeviceControl = class(TFrame)
    ButtonPanel: TPanel;
    TextPanel: TPanel;
    DeviceLabel: TLabel;
    StatusLabel: TLabel;
    SelectButton: TButton;
    ConnectionButton: TButton;
    procedure SelectButtonClick(Sender: TObject);
    procedure ConnectionButtonClick(Sender: TObject);
  private
    FClient: TLazBleLclClient;
    FShowSelectButton: Boolean;
    FShowConnectionButton: Boolean;
    FSelectButtonCaption: string;
    FConnectButtonCaption: string;
    FDisconnectButtonCaption: string;
    FOnSelectButtonClick: TNotifyEvent;
    FOnConnectionButtonClick: TNotifyEvent;
    function GetCanSelectDevice: Boolean;
    function GetCanToggleConnection: Boolean;
    function GetConnectionActionText: string;
    function GetDeviceText: string;
    function GetStatusText: string;
    function IsSelectButtonCaptionStored: Boolean;
    function IsConnectButtonCaptionStored: Boolean;
    function IsDisconnectButtonCaptionStored: Boolean;
    procedure SetClient(const AValue: TLazBleLclClient);
    procedure SetShowSelectButton(const AValue: Boolean);
    procedure SetShowConnectionButton(const AValue: Boolean);
    procedure SetSelectButtonCaption(const AValue: string);
    procedure SetConnectButtonCaption(const AValue: string);
    procedure SetDisconnectButtonCaption(const AValue: string);
    procedure ClientChanged(Sender: TObject);
    procedure RefreshDisplay;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
    procedure Loaded; override;
    function ExecuteDeviceSelection(out ADevice: TBleDeviceInfo): Boolean;
      virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Open the device picker and assign the selected device to Client. }
    procedure SelectDevice;
    { Run the currently available connect or disconnect action. }
    procedure ToggleConnection;
    property DeviceText: string read GetDeviceText;
    property StatusText: string read GetStatusText;
    property ConnectionActionText: string read GetConnectionActionText;
    property CanSelectDevice: Boolean read GetCanSelectDevice;
    property CanToggleConnection: Boolean read GetCanToggleConnection;
  published
    property Client: TLazBleLclClient read FClient write SetClient;
    property ShowSelectButton: Boolean read FShowSelectButton
      write SetShowSelectButton default True;
    property ShowConnectionButton: Boolean read FShowConnectionButton
      write SetShowConnectionButton default True;
    property SelectButtonCaption: string read FSelectButtonCaption
      write SetSelectButtonCaption stored IsSelectButtonCaptionStored;
    property ConnectButtonCaption: string read FConnectButtonCaption
      write SetConnectButtonCaption stored IsConnectButtonCaptionStored;
    property DisconnectButtonCaption: string read FDisconnectButtonCaption
      write SetDisconnectButtonCaption stored IsDisconnectButtonCaptionStored;
    property OnSelectButtonClick: TNotifyEvent read FOnSelectButtonClick
      write FOnSelectButtonClick;
    property OnConnectionButtonClick: TNotifyEvent
      read FOnConnectionButtonClick write FOnConnectionButtonClick;
    property Align;
    property Anchors;
    property AutoSize;
    property BorderSpacing;
    property Color;
    property Constraints;
    property Enabled;
    property Font;
    property ParentColor;
    property ParentFont;
    property ParentShowHint;
    property PopupMenu;
    property ShowHint;
    property TabOrder;
    property TabStop;
    property Visible;
  end;

implementation

{$R *.lfm}

resourcestring
  SBleNoClient = 'No BLE client assigned';
  SBleNoDevice = 'No device selected';
  SBleCheckingAvailability = 'Checking Bluetooth availability...';
  SBleUnavailable = 'Bluetooth unavailable';
  SBleUnavailableDetail = 'Bluetooth unavailable: %s';
  SBleScanning = 'Scanning for Bluetooth devices...';
  SBleDisconnected = 'Disconnected';
  SBleConnecting = 'Connecting...';
  SBleAttachingProfiles = 'Preparing services...';
  SBleConnected = 'Connected';
  SBleWaitingToReconnect = 'Waiting to reconnect...';
  SBleDisconnecting = 'Disconnecting...';
  SBleConnectionError = 'Connection error';
  SBleConnectionErrorDetail = 'Connection error: %s';
  SBleSelect = 'Select...';
  SBleConnect = 'Connect';
  SBleDisconnect = 'Disconnect';

function LazBleDeviceText(const AClient: TLazBleLclClient): string;
begin
  if not Assigned(AClient) then
    Exit(SBleNoClient);
  if AClient.DeviceName <> '' then
    Exit(AClient.DeviceName);
  if AClient.DeviceId <> '' then
    Exit(AClient.DeviceId);
  Result := SBleNoDevice;
end;

function LazBleStatusText(const AClient: TLazBleLclClient): string;
begin
  if not Assigned(AClient) then
    Exit('');
  if Assigned(AClient.LazBle) then
  begin
    case AClient.LazBle.Availability of
      lbaChecking: Exit(SBleCheckingAvailability);
      lbaUnavailable:
        if AClient.LazBle.LastErrorMessage <> '' then
          Exit(Format(SBleUnavailableDetail,
            [AClient.LazBle.LastErrorMessage]))
        else
          Exit(SBleUnavailable);
    end;
    if AClient.LazBle.ScanState = lblssScanning then
      Exit(SBleScanning);
  end;
  case AClient.State of
    lbcstDisconnected: Result := SBleDisconnected;
    lbcstConnecting: Result := SBleConnecting;
    lbcstAttachingProfiles: Result := SBleAttachingProfiles;
    lbcstReady: Result := SBleConnected;
    lbcstWaitingToReconnect: Result := SBleWaitingToReconnect;
    lbcstDisconnecting: Result := SBleDisconnecting;
    lbcstError:
      if AClient.LastErrorMessage <> '' then
        Result := Format(SBleConnectionErrorDetail,
          [AClient.LastErrorMessage])
      else
        Result := SBleConnectionError;
  end;
end;

function LazBleCanStartNewOperation(
  const AClient: TLazBleLclClient): Boolean;
begin
  Result := Assigned(AClient) and Assigned(AClient.LazBle) and
    (AClient.LazBle.Availability in [lbaUnknown, lbaAvailable]) and
    (AClient.LazBle.ScanState <> lblssScanning);
end;

function LazBleCanSelectDevice(const AClient: TLazBleLclClient): Boolean;
begin
  Result := LazBleCanStartNewOperation(AClient) and
    (AClient.State in [lbcstDisconnected, lbcstError]);
end;

function LazBleConnectionAction(
  const AClient: TLazBleLclClient): TLazBleConnectionAction;
begin
  Result := lbcaNone;
  if not Assigned(AClient) or not Assigned(AClient.LazBle) then
    Exit;
  if AClient.State in [lbcstConnecting, lbcstAttachingProfiles,
    lbcstReady, lbcstWaitingToReconnect] then
    Exit(lbcaDisconnect);
  if (AClient.DeviceId <> '') and LazBleCanStartNewOperation(AClient) and
    (AClient.State in [lbcstDisconnected, lbcstError]) then
    Result := lbcaConnect;
end;

function LazBleConnectionActionText(
  const AClient: TLazBleLclClient): string;
begin
  if (LazBleConnectionAction(AClient) = lbcaDisconnect) or
    (Assigned(AClient) and (AClient.State = lbcstDisconnecting)) then
    Result := SBleDisconnect
  else
    Result := SBleConnect;
end;

constructor TLazBleDeviceControl.Create(AOwner: TComponent);
begin
  FShowSelectButton := True;
  FShowConnectionButton := True;
  FSelectButtonCaption := SBleSelect;
  FConnectButtonCaption := SBleConnect;
  FDisconnectButtonCaption := SBleDisconnect;
  inherited Create(AOwner);
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.Loaded;
begin
  inherited Loaded;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetShowSelectButton(const AValue: Boolean);
begin
  if AValue = FShowSelectButton then
    Exit;
  FShowSelectButton := AValue;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetShowConnectionButton(const AValue: Boolean);
begin
  if AValue = FShowConnectionButton then
    Exit;
  FShowConnectionButton := AValue;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetSelectButtonCaption(const AValue: string);
begin
  if AValue = FSelectButtonCaption then
    Exit;
  FSelectButtonCaption := AValue;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetConnectButtonCaption(const AValue: string);
begin
  if AValue = FConnectButtonCaption then
    Exit;
  FConnectButtonCaption := AValue;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetDisconnectButtonCaption(const AValue: string);
begin
  if AValue = FDisconnectButtonCaption then
    Exit;
  FDisconnectButtonCaption := AValue;
  RefreshDisplay;
end;

function TLazBleDeviceControl.IsSelectButtonCaptionStored: Boolean;
begin
  Result := FSelectButtonCaption <> SBleSelect;
end;

function TLazBleDeviceControl.IsConnectButtonCaptionStored: Boolean;
begin
  Result := FConnectButtonCaption <> SBleConnect;
end;

function TLazBleDeviceControl.IsDisconnectButtonCaptionStored: Boolean;
begin
  Result := FDisconnectButtonCaption <> SBleDisconnect;
end;

destructor TLazBleDeviceControl.Destroy;
begin
  Client := nil;
  inherited Destroy;
end;

procedure TLazBleDeviceControl.SetClient(const AValue: TLazBleLclClient);
begin
  if AValue = FClient then
    Exit;
  if Assigned(FClient) then
  begin
    FClient.RemoveChangedHandler(@ClientChanged);
    FClient.RemoveFreeNotification(Self);
  end;
  FClient := AValue;
  if Assigned(FClient) then
  begin
    FClient.FreeNotification(Self);
    FClient.AddChangedHandler(@ClientChanged);
  end;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = FClient) then
  begin
    FClient := nil;
    RefreshDisplay;
  end;
end;

procedure TLazBleDeviceControl.ClientChanged(Sender: TObject);
begin
  RefreshDisplay;
end;

function TLazBleDeviceControl.GetCanSelectDevice: Boolean;
begin
  Result := LazBleCanSelectDevice(FClient);
end;

function TLazBleDeviceControl.GetCanToggleConnection: Boolean;
begin
  Result := LazBleConnectionAction(FClient) <> lbcaNone;
end;

function TLazBleDeviceControl.GetConnectionActionText: string;
begin
  if Assigned(FClient) and
    ((LazBleConnectionAction(FClient) = lbcaDisconnect) or
    (FClient.State = lbcstDisconnecting)) then
    Result := FDisconnectButtonCaption
  else
    Result := FConnectButtonCaption;
end;

function TLazBleDeviceControl.GetDeviceText: string;
begin
  Result := LazBleDeviceText(FClient);
end;

function TLazBleDeviceControl.GetStatusText: string;
begin
  Result := LazBleStatusText(FClient);
end;

procedure TLazBleDeviceControl.RefreshDisplay;
begin
  if not Assigned(DeviceLabel) or not Assigned(StatusLabel) or
    not Assigned(SelectButton) or not Assigned(ConnectionButton) then
    Exit;
  DeviceLabel.Caption := DeviceText;
  StatusLabel.Caption := StatusText;
  SelectButton.Caption := FSelectButtonCaption;
  SelectButton.Visible := FShowSelectButton;
  SelectButton.Enabled := Enabled and CanSelectDevice;
  ConnectionButton.Visible := FShowConnectionButton;
  ConnectionButton.Caption := ConnectionActionText;
  ConnectionButton.Enabled := Enabled and CanToggleConnection;
  Invalidate;
end;

function TLazBleDeviceControl.ExecuteDeviceSelection(
  out ADevice: TBleDeviceInfo): Boolean;
var
  Dialog: TBleDeviceSelectForm;
begin
  ADevice := Default(TBleDeviceInfo);
  if not CanSelectDevice then
    Exit(False);
  Dialog := TBleDeviceSelectForm.Create(nil,
    FClient.LazBle.ScanController);
  try
    Dialog.AdapterId := FClient.LazBle.AdapterId;
    Dialog.ScanTimeoutMs := FClient.LazBle.ScanTimeoutMs;
    Result := Dialog.Execute(ADevice);
  finally
    Dialog.Free;
  end;
end;

procedure TLazBleDeviceControl.SelectDevice;
var
  Device: TBleDeviceInfo;
begin
  if ExecuteDeviceSelection(Device) and (Device.DeviceId <> '') then
    FClient.SelectDevice(Device);
end;

procedure TLazBleDeviceControl.ToggleConnection;
begin
  case LazBleConnectionAction(FClient) of
    lbcaConnect: FClient.Connect;
    lbcaDisconnect: FClient.Disconnect;
  end;
end;

procedure TLazBleDeviceControl.SelectButtonClick(Sender: TObject);
begin
  if Assigned(FOnSelectButtonClick) then
    FOnSelectButtonClick(Self)
  else
    SelectDevice;
end;

procedure TLazBleDeviceControl.ConnectionButtonClick(Sender: TObject);
begin
  if Assigned(FOnConnectionButtonClick) then
    FOnConnectionButtonClick(Self)
  else
    ToggleConnection;
end;

initialization
  RegisterClass(TLazBleDeviceControl);

finalization
  UnregisterClass(TLazBleDeviceControl);

end.
