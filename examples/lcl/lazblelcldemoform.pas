unit LazBleLclDemoForm;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  LazBleTypes, LazBleClient, LazBleOperation, LazBleComponent,
  LazBleLclScan, LazBleDeviceSelectForm;

type
  TLazBleDemoForm = class(TForm)
    BleClient: TLazBleLclClient;
    LazBle: TLazBleComponent;
    DevicePanel: TPanel;
    DeviceButton: TButton;
    ConnectionButton: TButton;
    StatusPanel: TPanel;
    StatusIndicator: TShape;
    StatusLabel: TLabel;
    ErrorLabel: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure DeviceButtonClick(Sender: TObject);
    procedure ConnectionButtonClick(Sender: TObject);
  private
    FShutdown: IBleOperation;
    function CanStartOperation: Boolean;
    function CanDisconnect: Boolean;
    procedure ClientChanged(Sender: TObject);
    procedure RefreshDisplay;
    procedure ShutdownCompleted(Sender: TObject);
    procedure FinishClose(Data: PtrInt);
  public
    destructor Destroy; override;
  end;

var
  LazBleDemoForm: TLazBleDemoForm;

implementation

{$R *.lfm}

const
  DeviceMenuSuffix: UTF8String = ' ▾';

resourcestring
  SBleSelectDevice = 'Select a device...';
  SBleConnect = 'Connect';
  SBleDisconnect = 'Disconnect';
  SBleDisconnected = 'Disconnected';
  SBleConnecting = 'Connecting...';
  SBleAttachingProfiles = 'Preparing services...';
  SBleConnected = 'Connected';
  SBleWaitingToReconnect = 'Waiting to reconnect...';
  SBleDisconnecting = 'Disconnecting...';
  SBleConnectionError = 'Connection error';
  SBleCheckingAvailability = 'Checking Bluetooth availability...';
  SBleUnavailable = 'Bluetooth unavailable';
  SBleScanning = 'Scanning for Bluetooth devices...';

procedure TLazBleDemoForm.FormCreate(Sender: TObject);
begin
  BleClient.AddChangedHandler(@ClientChanged);
  RefreshDisplay;
end;

function TLazBleDemoForm.CanStartOperation: Boolean;
begin
  Result := (FShutdown = nil) and
    (LazBle.Availability in [lbaUnknown, lbaAvailable]) and
    (LazBle.ScanState <> lblssScanning);
end;

function TLazBleDemoForm.CanDisconnect: Boolean;
begin
  Result := BleClient.State in [lbcstConnecting, lbcstAttachingProfiles,
    lbcstReady, lbcstWaitingToReconnect];
end;

procedure TLazBleDemoForm.ClientChanged(Sender: TObject);
begin
  if not (csDestroying in ComponentState) then
    RefreshDisplay;
end;

procedure TLazBleDemoForm.RefreshDisplay;
var
  Status: string;
  StatusColor: TColor;
begin
  if BleClient.DeviceName <> '' then
    DeviceButton.Caption := BleClient.DeviceName
  else if BleClient.DeviceId <> '' then
    DeviceButton.Caption := BleClient.DeviceId
  else
    DeviceButton.Caption := SBleSelectDevice;
  DeviceButton.Caption := StringReplace(DeviceButton.Caption, '&', '&&',
    [rfReplaceAll]) + DeviceMenuSuffix;
  DeviceButton.Hint := BleClient.DeviceId;
  DeviceButton.Enabled := CanStartOperation and
    (BleClient.State in [lbcstDisconnected, lbcstError]);

  if CanDisconnect or (BleClient.State = lbcstDisconnecting) then
    ConnectionButton.Caption := SBleDisconnect
  else
    ConnectionButton.Caption := SBleConnect;
  ConnectionButton.Enabled := (FShutdown = nil) and
    (CanDisconnect or (CanStartOperation and (BleClient.DeviceId <> '') and
      (BleClient.State in [lbcstDisconnected, lbcstError])));

  Status := '';
  StatusColor := clGray;
  ErrorLabel.Caption := '';
  case BleClient.State of
    lbcstDisconnected:
      if BleClient.DeviceId <> '' then Status := SBleDisconnected;
    lbcstConnecting: Status := SBleConnecting;
    lbcstAttachingProfiles: Status := SBleAttachingProfiles;
    lbcstReady: Status := SBleConnected;
    lbcstWaitingToReconnect: Status := SBleWaitingToReconnect;
    lbcstDisconnecting: Status := SBleDisconnecting;
    lbcstError:
      begin
        Status := SBleConnectionError;
        ErrorLabel.Caption := BleClient.LastErrorMessage;
      end;
  end;
  case BleClient.State of
    lbcstReady: StatusColor := clGreen;
    lbcstConnecting, lbcstAttachingProfiles, lbcstWaitingToReconnect,
      lbcstDisconnecting: StatusColor := clOlive;
    lbcstError: StatusColor := clRed;
  end;
  case LazBle.Availability of
    lbaChecking:
      begin
        Status := SBleCheckingAvailability;
        StatusColor := clOlive;
      end;
    lbaUnavailable:
      begin
        Status := SBleUnavailable;
        StatusColor := clRed;
        ErrorLabel.Caption := LazBle.LastErrorMessage;
      end;
  else
    if LazBle.ScanState = lblssScanning then
    begin
      Status := SBleScanning;
      StatusColor := clOlive;
    end;
  end;
  StatusPanel.Visible := Status <> '';
  StatusLabel.Caption := Status;
  StatusIndicator.Brush.Color := StatusColor;
  ErrorLabel.Visible := ErrorLabel.Caption <> '';
end;

procedure TLazBleDemoForm.DeviceButtonClick(Sender: TObject);
var
  Dialog: TBleDeviceSelectForm;
  Device: TBleDeviceInfo;
begin
  if not DeviceButton.Enabled then Exit;
  Dialog := TBleDeviceSelectForm.Create(nil, LazBle.ScanController);
  try
    Dialog.AdapterId := LazBle.AdapterId;
    Dialog.ScanTimeoutMs := LazBle.ScanTimeoutMs;
    if Dialog.Execute(Device) then
      BleClient.SelectDevice(Device);
  finally
    Dialog.Free;
  end;
end;

procedure TLazBleDemoForm.ConnectionButtonClick(Sender: TObject);
begin
  if not ConnectionButton.Enabled then Exit;
  if CanDisconnect then BleClient.Disconnect else BleClient.Connect;
end;

procedure TLazBleDemoForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := Assigned(FShutdown) and (FShutdown.State <> lbopPending);
  if CanClose or Assigned(FShutdown) then Exit;
  Enabled := False;
  FShutdown := LazBle.ShutdownAsync;
  FShutdown.OnCompleted := @ShutdownCompleted;
end;

procedure TLazBleDemoForm.ShutdownCompleted(Sender: TObject);
begin
  Application.QueueAsyncCall(@FinishClose, 0);
end;

procedure TLazBleDemoForm.FinishClose(Data: PtrInt);
begin
  Close;
end;

destructor TLazBleDemoForm.Destroy;
begin
  if Assigned(BleClient) then
    BleClient.RemoveChangedHandler(@ClientChanged);
  if Assigned(FShutdown) then FShutdown.OnCompleted := nil;
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

end.
