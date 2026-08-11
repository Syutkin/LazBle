unit LazBleDeviceSelectForm;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  StdCtrls,
  ExtCtrls,
  Grids,
  LazBleTypes,
  LazBleLclScan;

type
  TBleDeviceSelectForm = class(TForm)
    ButtonCancel: TButton;
    ButtonSelect: TButton;
    ButtonStart: TButton;
    ButtonStop: TButton;
    ButtonPanel: TPanel;
    DeviceGrid: TStringGrid;
    StatusLabel: TLabel;
    procedure ButtonSelectClick(Sender: TObject);
    procedure ButtonStartClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure DeviceGridDblClick(Sender: TObject);
    procedure DeviceGridSelection(Sender: TObject; ACol, ARow: Integer);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FScan: TLazBleLclScan;
    FAdapterId: string;
    FScanTimeoutMs: Cardinal;
    FDevices: TBleDeviceInfos;
    FSelectedIndex: Integer;
    FStartedScan: Boolean;
    FPreviousOnResult: TLazBleScanResultEvent;
    FPreviousOnStateChanged: TLazBleLclScanStateChangedEvent;
    FPreviousOnCompleted: TLazBleLclScanCompletedEvent;
    function GetDevice(const AIndex: Integer): TBleDeviceInfo;
    function GetDeviceCount: Integer;
    function GetScanState: TLazBleLclScanState;
    procedure SetScan(const AValue: TLazBleLclScan);
    procedure SetSelectedIndex(const AValue: Integer);
    procedure AttachScanHandlers;
    procedure DetachScanHandlers;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure RefreshDevices;
    procedure RefreshControls;
    procedure ApplyTranslations;
    procedure AcceptSelection;
  public
    constructor Create(AOwner: TComponent); override; overload;
    constructor Create(AOwner: TComponent;
      const AScan: TLazBleLclScan); reintroduce; overload;
    destructor Destroy; override;
    procedure StartScan;
    procedure StopScan;
    function Execute(out ADevice: TBleDeviceInfo): Boolean;
    function TryGetSelectedDevice(out ADevice: TBleDeviceInfo): Boolean;
    property Scan: TLazBleLclScan read FScan write SetScan;
    property AdapterId: string read FAdapterId write FAdapterId;
    property ScanTimeoutMs: Cardinal read FScanTimeoutMs write FScanTimeoutMs;
    property ScanState: TLazBleLclScanState read GetScanState;
    property DeviceCount: Integer read GetDeviceCount;
    property Devices[const AIndex: Integer]: TBleDeviceInfo read GetDevice;
    property SelectedIndex: Integer read FSelectedIndex write SetSelectedIndex;
  end;

const
  DefaultBleDeviceSelectScanTimeoutMs = 10000;

implementation

{$R *.lfm}

resourcestring
  SBleDeviceSelectTitle = 'Bluetooth devices';
  SBleDeviceSelectNameColumn = 'Name';
  SBleDeviceSelectIdColumn = 'Device ID';
  SBleDeviceSelectRssiColumn = 'RSSI';
  SBleDeviceSelectStart = 'Start';
  SBleDeviceSelectStop = 'Stop';
  SBleDeviceSelectSelect = 'Select';
  SBleDeviceSelectCancel = 'Cancel';
  SBleDeviceSelectIdle = 'Ready to scan';
  SBleDeviceSelectScanning = 'Scanning for Bluetooth devices...';
  SBleDeviceSelectSucceeded = 'Scan completed';
  SBleDeviceSelectCancelled = 'Scan cancelled';
  SBleDeviceSelectTimedOut = 'Scan timed out';
  SBleDeviceSelectFailed = 'Scan failed';
  SBleDeviceSelectError = '%s: %s';

constructor TBleDeviceSelectForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScanTimeoutMs := DefaultBleDeviceSelectScanTimeoutMs;
  FSelectedIndex := -1;
  ApplyTranslations;
  RefreshDevices;
  RefreshControls;
end;

constructor TBleDeviceSelectForm.Create(AOwner: TComponent;
  const AScan: TLazBleLclScan);
begin
  Create(AOwner);
  Scan := AScan;
end;

destructor TBleDeviceSelectForm.Destroy;
begin
  if FStartedScan and Assigned(FScan) and
    (FScan.State = lblssScanning) then
    FScan.Cancel;
  DetachScanHandlers;
  FScan := nil;
  inherited Destroy;
end;

procedure TBleDeviceSelectForm.SetScan(const AValue: TLazBleLclScan);
begin
  if AValue = FScan then
    Exit;
  if FStartedScan and Assigned(FScan) and
    (FScan.State = lblssScanning) then
    FScan.Cancel;
  DetachScanHandlers;
  FStartedScan := False;
  FScan := AValue;
  AttachScanHandlers;
  RefreshDevices;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.AttachScanHandlers;
begin
  if not Assigned(FScan) then
    Exit;
  FPreviousOnResult := FScan.OnResult;
  FPreviousOnStateChanged := FScan.OnStateChanged;
  FPreviousOnCompleted := FScan.OnCompleted;
  FScan.OnResult := @ScanResult;
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnCompleted := @ScanCompleted;
end;

procedure TBleDeviceSelectForm.DetachScanHandlers;
begin
  if not Assigned(FScan) then
    Exit;
  FScan.OnResult := FPreviousOnResult;
  FScan.OnStateChanged := FPreviousOnStateChanged;
  FScan.OnCompleted := FPreviousOnCompleted;
  FPreviousOnResult := nil;
  FPreviousOnStateChanged := nil;
  FPreviousOnCompleted := nil;
end;

procedure TBleDeviceSelectForm.StartScan;
begin
  if not Assigned(FScan) then
    raise EInvalidOperation.Create('BLE scan controller is not assigned');
  FSelectedIndex := -1;
  FScan.Start(FAdapterId, FScanTimeoutMs);
  FStartedScan := True;
  RefreshDevices;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.StopScan;
begin
  if Assigned(FScan) and (FScan.State = lblssScanning) then
    FScan.Cancel;
end;

function TBleDeviceSelectForm.Execute(out ADevice: TBleDeviceInfo): Boolean;
begin
  ADevice := Default(TBleDeviceInfo);
  if not Assigned(FScan) then
    raise EInvalidOperation.Create('BLE scan controller is not assigned');
  if FScan.State <> lblssScanning then
    StartScan
  else
  begin
    RefreshDevices;
    RefreshControls;
  end;
  Result := ShowModal = mrOk;
  if Result then
    Result := TryGetSelectedDevice(ADevice);
end;

function TBleDeviceSelectForm.TryGetSelectedDevice(
  out ADevice: TBleDeviceInfo): Boolean;
begin
  Result := (FSelectedIndex >= 0) and
    (FSelectedIndex < Length(FDevices));
  if Result then
    ADevice := FDevices[FSelectedIndex]
  else
    ADevice := Default(TBleDeviceInfo);
end;

function TBleDeviceSelectForm.GetDevice(
  const AIndex: Integer): TBleDeviceInfo;
begin
  if (AIndex < 0) or (AIndex >= Length(FDevices)) then
    raise EArgumentOutOfRangeException.Create('AIndex');
  Result := FDevices[AIndex];
end;

function TBleDeviceSelectForm.GetDeviceCount: Integer;
begin
  Result := Length(FDevices);
end;

function TBleDeviceSelectForm.GetScanState: TLazBleLclScanState;
begin
  if Assigned(FScan) then
    Result := FScan.State
  else
    Result := lblssIdle;
end;

procedure TBleDeviceSelectForm.SetSelectedIndex(const AValue: Integer);
begin
  if (AValue < -1) or (AValue >= Length(FDevices)) then
    raise EArgumentOutOfRangeException.Create('AValue');
  FSelectedIndex := AValue;
  if FSelectedIndex >= 0 then
    DeviceGrid.Row := FSelectedIndex + 1;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  Handler: TLazBleScanResultEvent;
begin
  Handler := FPreviousOnResult;
  if Assigned(Handler) then
    Handler(Sender, ADeviceId, ADeviceName, ARssi);
  RefreshDevices;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanStateChangedEvent;
begin
  Handler := FPreviousOnStateChanged;
  if Assigned(Handler) then
    Handler(Sender, AState);
  RefreshControls;
end;

procedure TBleDeviceSelectForm.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanCompletedEvent;
begin
  FStartedScan := False;
  Handler := FPreviousOnCompleted;
  if Assigned(Handler) then
    Handler(Sender, AState);
  RefreshDevices;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.RefreshDevices;
var
  DeviceIndex: Integer;
  PreviousDeviceId: string;
begin
  PreviousDeviceId := '';
  if (FSelectedIndex >= 0) and (FSelectedIndex < Length(FDevices)) then
    PreviousDeviceId := FDevices[FSelectedIndex].DeviceId;

  if Assigned(FScan) then
    FDevices := FScan.Results
  else
    SetLength(FDevices, 0);

  FSelectedIndex := -1;
  DeviceGrid.RowCount := Length(FDevices) + 1;
  for DeviceIndex := 0 to High(FDevices) do
  begin
    DeviceGrid.Cells[0, DeviceIndex + 1] := FDevices[DeviceIndex].DeviceName;
    DeviceGrid.Cells[1, DeviceIndex + 1] := FDevices[DeviceIndex].DeviceId;
    DeviceGrid.Cells[2, DeviceIndex + 1] := IntToStr(FDevices[DeviceIndex].Rssi);
    if (PreviousDeviceId <> '') and
      SameText(PreviousDeviceId, FDevices[DeviceIndex].DeviceId) then
      FSelectedIndex := DeviceIndex;
  end;
  if FSelectedIndex >= 0 then
    DeviceGrid.Row := FSelectedIndex + 1;
end;

procedure TBleDeviceSelectForm.RefreshControls;
var
  State: TLazBleLclScanState;
begin
  State := ScanState;
  case State of
    lblssIdle: StatusLabel.Caption := SBleDeviceSelectIdle;
    lblssScanning: StatusLabel.Caption := SBleDeviceSelectScanning;
    lblssSucceeded: StatusLabel.Caption := SBleDeviceSelectSucceeded;
    lblssCancelled: StatusLabel.Caption := SBleDeviceSelectCancelled;
    lblssTimedOut: StatusLabel.Caption := SBleDeviceSelectTimedOut;
    lblssFailed: StatusLabel.Caption := SBleDeviceSelectFailed;
  end;
  if (State in [lblssTimedOut, lblssFailed]) and
    (FScan.ErrorMessage <> '') then
    StatusLabel.Caption := Format(SBleDeviceSelectError,
      [StatusLabel.Caption, FScan.ErrorMessage]);
  ButtonStart.Enabled := Assigned(FScan) and (State <> lblssScanning);
  ButtonStop.Enabled := Assigned(FScan) and (State = lblssScanning);
  ButtonSelect.Enabled := (FSelectedIndex >= 0) and
    (FSelectedIndex < Length(FDevices));
end;

procedure TBleDeviceSelectForm.ApplyTranslations;
begin
  Caption := SBleDeviceSelectTitle;
  DeviceGrid.Columns[0].Title.Caption := SBleDeviceSelectNameColumn;
  DeviceGrid.Columns[1].Title.Caption := SBleDeviceSelectIdColumn;
  DeviceGrid.Columns[2].Title.Caption := SBleDeviceSelectRssiColumn;
  ButtonStart.Caption := SBleDeviceSelectStart;
  ButtonStop.Caption := SBleDeviceSelectStop;
  ButtonSelect.Caption := SBleDeviceSelectSelect;
  ButtonCancel.Caption := SBleDeviceSelectCancel;
end;

procedure TBleDeviceSelectForm.AcceptSelection;
var
  Device: TBleDeviceInfo;
begin
  if TryGetSelectedDevice(Device) then
    ModalResult := mrOk;
end;

procedure TBleDeviceSelectForm.ButtonStartClick(Sender: TObject);
begin
  StartScan;
end;

procedure TBleDeviceSelectForm.ButtonStopClick(Sender: TObject);
begin
  StopScan;
end;

procedure TBleDeviceSelectForm.ButtonSelectClick(Sender: TObject);
begin
  AcceptSelection;
end;

procedure TBleDeviceSelectForm.DeviceGridDblClick(Sender: TObject);
begin
  AcceptSelection;
end;

procedure TBleDeviceSelectForm.DeviceGridSelection(Sender: TObject;
  ACol, ARow: Integer);
begin
  if ARow > 0 then
    FSelectedIndex := ARow - 1
  else
    FSelectedIndex := -1;
  RefreshControls;
end;

procedure TBleDeviceSelectForm.FormCloseQuery(Sender: TObject;
  var CanClose: Boolean);
begin
  if FStartedScan then
    StopScan;
  CanClose := True;
end;

end.
