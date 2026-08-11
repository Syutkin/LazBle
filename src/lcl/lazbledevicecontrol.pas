unit LazBleDeviceControl;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  Controls,
  Graphics,
  StdCtrls,
  LazBleTypes,
  LazBleClient,
  LazBleComponent,
  LazBleLclScan,
  LazBleDeviceSelectForm;

function LazBleDeviceText(const AClient: TLazBleLclClient): string;
function LazBleStatusText(const AClient: TLazBleLclClient): string;

type
  TLazBleDeviceControl = class(TCustomControl)
  private
    FClient: TLazBleLclClient;
    FDeviceLabel: TLabel;
    FStatusLabel: TLabel;
    FSelectButton: TButton;
    FConnectionButton: TButton;
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
    procedure SelectButtonClick(Sender: TObject);
    procedure ConnectionButtonClick(Sender: TObject);
    procedure RefreshDisplay;
  protected
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;
    procedure Paint; override;
    procedure Resize; override;
    function ExecuteDeviceSelection(out ADevice: TBleDeviceInfo): Boolean;
      virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SelectDevice;
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

constructor TLazBleDeviceControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 480;
  Height := 64;
  ParentColor := True;
  FShowSelectButton := True;
  FShowConnectionButton := True;
  FSelectButtonCaption := SBleSelect;
  FConnectButtonCaption := SBleConnect;
  FDisconnectButtonCaption := SBleDisconnect;

  FDeviceLabel := TLabel.Create(Self);
  FDeviceLabel.Parent := Self;
  FDeviceLabel.AutoSize := False;
  FDeviceLabel.ParentFont := True;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Self;
  FStatusLabel.AutoSize := False;
  FStatusLabel.ParentFont := True;

  FSelectButton := TButton.Create(Self);
  FSelectButton.Parent := Self;
  FSelectButton.Caption := FSelectButtonCaption;
  FSelectButton.OnClick := @SelectButtonClick;

  FConnectionButton := TButton.Create(Self);
  FConnectionButton.Parent := Self;
  FConnectionButton.OnClick := @ConnectionButtonClick;

  Resize;
  RefreshDisplay;
end;

procedure TLazBleDeviceControl.SetShowSelectButton(const AValue: Boolean);
begin
  if AValue = FShowSelectButton then
    Exit;
  FShowSelectButton := AValue;
  FSelectButton.Visible := AValue;
  Resize;
end;

procedure TLazBleDeviceControl.SetShowConnectionButton(const AValue: Boolean);
begin
  if AValue = FShowConnectionButton then
    Exit;
  FShowConnectionButton := AValue;
  FConnectionButton.Visible := AValue;
  Resize;
end;

procedure TLazBleDeviceControl.SetSelectButtonCaption(const AValue: string);
begin
  if AValue = FSelectButtonCaption then
    Exit;
  FSelectButtonCaption := AValue;
  FSelectButton.Caption := AValue;
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
  Result := Assigned(FClient) and Assigned(FClient.LazBle) and
    (FClient.State in [lbcstDisconnected, lbcstError]);
end;

function TLazBleDeviceControl.GetCanToggleConnection: Boolean;
begin
  Result := Assigned(FClient) and Assigned(FClient.LazBle) and
    (FClient.DeviceId <> '') and (FClient.State <> lbcstDisconnecting);
end;

function TLazBleDeviceControl.GetConnectionActionText: string;
begin
  if Assigned(FClient) and
    (FClient.State in [lbcstConnecting, lbcstAttachingProfiles,
      lbcstReady, lbcstWaitingToReconnect]) then
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
  FDeviceLabel.Caption := DeviceText;
  FStatusLabel.Caption := StatusText;
  FSelectButton.Caption := FSelectButtonCaption;
  FSelectButton.Visible := FShowSelectButton;
  FSelectButton.Enabled := Enabled and CanSelectDevice;
  FConnectionButton.Visible := FShowConnectionButton;
  FConnectionButton.Caption := ConnectionActionText;
  FConnectionButton.Enabled := Enabled and CanToggleConnection;
  Invalidate;
end;

procedure TLazBleDeviceControl.Resize;
const
  Margin = 8;
  ButtonGap = 6;
  SelectButtonWidth = 84;
  ConnectionButtonWidth = 96;
var
  HasVisibleButton: Boolean;
  ButtonHeight: Integer;
  LabelWidth: Integer;
  RightEdge: Integer;
begin
  inherited Resize;
  if not Assigned(FConnectionButton) or not Assigned(FSelectButton) or
    not Assigned(FDeviceLabel) or not Assigned(FStatusLabel) then
    Exit;
  ButtonHeight := 30;
  HasVisibleButton := FShowConnectionButton or FShowSelectButton;
  RightEdge := Width - Margin;
  if FShowConnectionButton then
  begin
    FConnectionButton.SetBounds(RightEdge - ConnectionButtonWidth,
      (Height - ButtonHeight) div 2, ConnectionButtonWidth, ButtonHeight);
    RightEdge := FConnectionButton.Left - ButtonGap;
  end;
  if FShowSelectButton then
  begin
    FSelectButton.SetBounds(RightEdge - SelectButtonWidth,
      (Height - ButtonHeight) div 2, SelectButtonWidth, ButtonHeight);
    RightEdge := FSelectButton.Left - ButtonGap;
  end;
  if HasVisibleButton then
    LabelWidth := RightEdge + ButtonGap - Margin
  else
    LabelWidth := RightEdge - Margin;
  if LabelWidth < 0 then
    LabelWidth := 0;
  FDeviceLabel.SetBounds(Margin, 8, LabelWidth, 22);
  FStatusLabel.SetBounds(Margin, 34, LabelWidth, 20);
end;

procedure TLazBleDeviceControl.Paint;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
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
  if not CanToggleConnection then
    Exit;
  if FClient.State in [lbcstDisconnected, lbcstError] then
    FClient.Connect
  else
    FClient.Disconnect;
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
