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
  LazBleDeviceSelectForm;

type
  TLazBleDeviceControl = class(TCustomControl)
  private
    FClient: TLazBleLclClient;
    FDeviceLabel: TLabel;
    FStatusLabel: TLabel;
    FSelectButton: TButton;
    FConnectionButton: TButton;
    function GetCanSelectDevice: Boolean;
    function GetCanToggleConnection: Boolean;
    function GetConnectionActionText: string;
    function GetDeviceText: string;
    function GetStatusText: string;
    procedure SetClient(const AValue: TLazBleLclClient);
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

constructor TLazBleDeviceControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 480;
  Height := 64;
  ParentColor := True;

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
  FSelectButton.Caption := SBleSelect;
  FSelectButton.OnClick := @SelectButtonClick;

  FConnectionButton := TButton.Create(Self);
  FConnectionButton.Parent := Self;
  FConnectionButton.OnClick := @ConnectionButtonClick;

  Resize;
  RefreshDisplay;
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
    Result := SBleDisconnect
  else
    Result := SBleConnect;
end;

function TLazBleDeviceControl.GetDeviceText: string;
begin
  if not Assigned(FClient) then
    Exit(SBleNoClient);
  if FClient.DeviceName <> '' then
    Exit(FClient.DeviceName);
  if FClient.DeviceId <> '' then
    Exit(FClient.DeviceId);
  Result := SBleNoDevice;
end;

function TLazBleDeviceControl.GetStatusText: string;
begin
  if not Assigned(FClient) then
    Exit('');
  case FClient.State of
    lbcstDisconnected: Result := SBleDisconnected;
    lbcstConnecting: Result := SBleConnecting;
    lbcstAttachingProfiles: Result := SBleAttachingProfiles;
    lbcstReady: Result := SBleConnected;
    lbcstWaitingToReconnect: Result := SBleWaitingToReconnect;
    lbcstDisconnecting: Result := SBleDisconnecting;
    lbcstError:
      if FClient.LastErrorMessage <> '' then
        Result := Format(SBleConnectionErrorDetail,
          [FClient.LastErrorMessage])
      else
        Result := SBleConnectionError;
  end;
end;

procedure TLazBleDeviceControl.RefreshDisplay;
begin
  FDeviceLabel.Caption := DeviceText;
  FStatusLabel.Caption := StatusText;
  FSelectButton.Enabled := Enabled and CanSelectDevice;
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
  ButtonHeight: Integer;
  LabelWidth: Integer;
begin
  inherited Resize;
  if not Assigned(FConnectionButton) or not Assigned(FSelectButton) or
    not Assigned(FDeviceLabel) or not Assigned(FStatusLabel) then
    Exit;
  ButtonHeight := 30;
  FConnectionButton.SetBounds(Width - Margin - ConnectionButtonWidth,
    (Height - ButtonHeight) div 2, ConnectionButtonWidth, ButtonHeight);
  FSelectButton.SetBounds(FConnectionButton.Left - ButtonGap -
    SelectButtonWidth, (Height - ButtonHeight) div 2,
    SelectButtonWidth, ButtonHeight);
  LabelWidth := FSelectButton.Left - (2 * Margin);
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
  SelectDevice;
end;

procedure TLazBleDeviceControl.ConnectionButtonClick(Sender: TObject);
begin
  ToggleConnection;
end;

initialization
  RegisterClass(TLazBleDeviceControl);

finalization
  UnregisterClass(TLazBleDeviceControl);

end.
