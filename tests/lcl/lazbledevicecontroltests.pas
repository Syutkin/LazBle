unit LazBleDeviceControlTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  FpcUnit,
  TestRegistry,
  LResources,
  LazBleTypes,
  LazBleBackend,
  LazBleClient,
  LazBleFacade,
  LazBleComponent,
  LazBleDeviceControl,
  StdCtrls,
  FakeLazBleBackend;

type
  TDeviceControlStreamingOwner = class(TComponent)
  protected
    procedure GetChildren(Proc: TGetChildProc; Root: TComponent); override;
  end;

  TDeviceControlStreamingLazBle = class(TLazBleComponent)
  protected
    function CreateFacade: TLazBle; override;
  end;

  TTestLazBleDeviceControl = class(TLazBleDeviceControl)
  private
    FSelectionResult: Boolean;
    FSelectedDevice: TBleDeviceInfo;
  protected
    function ExecuteDeviceSelection(out ADevice: TBleDeviceInfo): Boolean;
      override;
  public
    property SelectionResult: Boolean read FSelectionResult
      write FSelectionResult;
    property SelectedDevice: TBleDeviceInfo read FSelectedDevice
      write FSelectedDevice;
  end;

  TLazBleDeviceControlTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FLazBle: TLazBleComponent;
    FClient: TLazBleLclClient;
    FControl: TTestLazBleDeviceControl;
    FConnectedCount: Integer;
    FSelectButtonClickCount: Integer;
    FConnectionButtonClickCount: Integer;
    FLastButtonClickSender: TObject;
    procedure ClientConnected(Sender: TObject);
    procedure SelectButtonClicked(Sender: TObject);
    procedure ConnectionButtonClicked(Sender: TObject);
    procedure FindComponentClass(Reader: TReader; const AClassName: string;
      var AClass: TComponentClass);
    function Button(const AIndex: Integer): TButton;
    function Device(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt): TBleDeviceInfo;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure BindingPreservesClientEventsAndStartsNoBleWork;
    procedure ButtonOptionsPreserveDefaultsAndUpdateControls;
    procedure CustomButtonEventsReplaceDefaultActions;
    procedure StreamingRestoresClientBindingWithoutBleWork;
    procedure SelectingDeviceUpdatesExistingClientWithoutConnecting;
    procedure DirectClientSelectionRefreshesControl;
    procedure ConnectActionUsesBoundClient;
    procedure ConnectActionRetriesAfterError;
    procedure StatusTextReflectsClientScanAndAvailabilityStates;
    procedure DestroyedClientClearsBinding;
    procedure RebindingStopsObservingPreviousClient;
  end;

implementation

var
  DeviceControlStreamingBackend: ILazBleBackend;

procedure TDeviceControlStreamingOwner.GetChildren(Proc: TGetChildProc;
  Root: TComponent);
var
  Index: Integer;
begin
  for Index := 0 to ComponentCount - 1 do
    Proc(Components[Index]);
end;

function TLazBleDeviceControlTest.Button(const AIndex: Integer): TButton;
var
  ButtonIndex: Integer;
  ControlIndex: Integer;
begin
  ButtonIndex := 0;
  for ControlIndex := 0 to FControl.ControlCount - 1 do
    if FControl.Controls[ControlIndex] is TButton then
    begin
      if ButtonIndex = AIndex then
        Exit(TButton(FControl.Controls[ControlIndex]));
      Inc(ButtonIndex);
    end;
  Result := nil;
end;

function TDeviceControlStreamingLazBle.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create(DeviceControlStreamingBackend);
end;

function TTestLazBleDeviceControl.ExecuteDeviceSelection(
  out ADevice: TBleDeviceInfo): Boolean;
begin
  ADevice := FSelectedDevice;
  Result := FSelectionResult;
end;

procedure TLazBleDeviceControlTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FLazBle := TLazBleComponent.Create(nil, FBackend);
  FClient := TLazBleLclClient.Create(nil);
  FClient.LazBle := FLazBle;
  FControl := TTestLazBleDeviceControl.Create(nil);
  FConnectedCount := 0;
  FSelectButtonClickCount := 0;
  FConnectionButtonClickCount := 0;
  FLastButtonClickSender := nil;
end;

procedure TLazBleDeviceControlTest.TearDown;
begin
  FControl.Free;
  FClient.Free;
  FLazBle.Free;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleDeviceControlTest.ClientConnected(Sender: TObject);
begin
  Inc(FConnectedCount);
end;

procedure TLazBleDeviceControlTest.SelectButtonClicked(Sender: TObject);
begin
  Inc(FSelectButtonClickCount);
  FLastButtonClickSender := Sender;
end;

procedure TLazBleDeviceControlTest.ConnectionButtonClicked(Sender: TObject);
begin
  Inc(FConnectionButtonClickCount);
  FLastButtonClickSender := Sender;
end;

procedure TLazBleDeviceControlTest.FindComponentClass(Reader: TReader;
  const AClassName: string; var AClass: TComponentClass);
begin
  AClass := TComponentClass(GetClass(AClassName));
end;

function TLazBleDeviceControlTest.Device(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt): TBleDeviceInfo;
begin
  Result := Default(TBleDeviceInfo);
  Result.DeviceId := ADeviceId;
  Result.DeviceName := ADeviceName;
  Result.Rssi := ARssi;
end;

procedure TLazBleDeviceControlTest.BindingPreservesClientEventsAndStartsNoBleWork;
var
  ConnectedHandler: TNotifyEvent;
begin
  FClient.OnConnected := @ClientConnected;
  ConnectedHandler := FClient.OnConnected;

  FControl.Client := FClient;

  AssertTrue(TMethod(FClient.OnConnected).Code =
    TMethod(ConnectedHandler).Code);
  AssertTrue(TMethod(FClient.OnConnected).Data =
    TMethod(ConnectedHandler).Data);
  AssertEquals(0, FBackendObject.CommandCount);
  AssertNull(FClient.CoreClient);
  AssertTrue(FControl.CanSelectDevice);
  AssertFalse(FControl.CanToggleConnection);
end;

procedure TLazBleDeviceControlTest.ButtonOptionsPreserveDefaultsAndUpdateControls;
begin
  AssertTrue(FControl.ShowSelectButton);
  AssertTrue(FControl.ShowConnectionButton);
  AssertEquals('Select...', FControl.SelectButtonCaption);
  AssertEquals('Connect', FControl.ConnectButtonCaption);
  AssertEquals('Disconnect', FControl.DisconnectButtonCaption);

  FControl.SelectButtonCaption := 'Choose';
  FControl.ConnectButtonCaption := 'Open';
  FControl.DisconnectButtonCaption := 'Close';
  FControl.ShowSelectButton := False;
  FControl.ShowConnectionButton := False;

  AssertEquals('Choose', Button(0).Caption);
  AssertFalse(Button(0).Visible);
  AssertEquals('Open', Button(1).Caption);
  AssertFalse(Button(1).Visible);
  AssertEquals('Open', FControl.ConnectionActionText);

  FClient.SelectDevice(Device('device-a', 'Timing unit', -45));
  FControl.Client := FClient;
  FControl.ToggleConnection;
  CheckSynchronize;

  AssertEquals('Close', FControl.ConnectionActionText);
  AssertEquals('Close', Button(1).Caption);
end;

procedure TLazBleDeviceControlTest.CustomButtonEventsReplaceDefaultActions;
begin
  FControl.Client := FClient;
  FControl.SelectionResult := True;
  FControl.SelectedDevice := Device('default-device', 'Default device', -45);
  FControl.OnSelectButtonClick := @SelectButtonClicked;

  Button(0).Click;

  AssertEquals(1, FSelectButtonClickCount);
  AssertSame(FControl, FLastButtonClickSender);
  AssertEquals('', FClient.DeviceId);

  FClient.SelectDevice(Device('custom-device', 'Custom device', -40));
  FControl.OnConnectionButtonClick := @ConnectionButtonClicked;

  Button(1).Click;

  AssertEquals(1, FConnectionButtonClickCount);
  AssertSame(FControl, FLastButtonClickSender);
  AssertEquals(0, FBackendObject.CommandCount);
  AssertNull(FClient.CoreClient);
end;

procedure TLazBleDeviceControlTest.StreamingRestoresClientBindingWithoutBleWork;
var
  Backend: ILazBleBackend;
  BackendObject: TFakeLazBleBackend;
  Loaded: TComponent;
  LoadedClient: TLazBleLclClient;
  LoadedControl: TLazBleDeviceControl;
  LoadedOwner: TDeviceControlStreamingOwner;
  Owner: TDeviceControlStreamingOwner;
  SourceClient: TLazBleLclClient;
  SourceControl: TLazBleDeviceControl;
  SourceLazBle: TDeviceControlStreamingLazBle;
  Stream: TMemoryStream;
begin
  FControl.Free;
  FControl := nil;
  FClient.Free;
  FClient := nil;
  FLazBle.Free;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  BackendObject := TFakeLazBleBackend.Create;
  Backend := BackendObject;
  DeviceControlStreamingBackend := Backend;
  Owner := TDeviceControlStreamingOwner.Create(nil);
  Owner.Name := 'StreamingOwner';
  LoadedOwner := nil;
  Stream := TMemoryStream.Create;
  try
    SourceLazBle := TDeviceControlStreamingLazBle.Create(Owner);
    SourceLazBle.Name := 'LazBle1';
    SourceClient := TLazBleLclClient.Create(Owner);
    SourceClient.Name := 'BleClient1';
    SourceClient.LazBle := SourceLazBle;
    SourceClient.DeviceId := 'streamed-device';
    SourceControl := TLazBleDeviceControl.Create(Owner);
    SourceControl.Name := 'BleDeviceControl1';
    SourceControl.Client := SourceClient;
    SourceControl.ShowSelectButton := False;
    SourceControl.ShowConnectionButton := False;
    SourceControl.SelectButtonCaption := 'Choose';
    SourceControl.ConnectButtonCaption := 'Open';
    SourceControl.DisconnectButtonCaption := 'Close';
    WriteComponentAsTextToStream(Stream, Owner);
    Owner.Free;
    Owner := nil;

    Stream.Position := 0;
    Loaded := nil;
    ReadComponentFromTextStream(Stream, Loaded, @FindComponentClass);
    LoadedOwner := Loaded as TDeviceControlStreamingOwner;
    LoadedClient := LoadedOwner.FindComponent('BleClient1') as
      TLazBleLclClient;
    LoadedControl := LoadedOwner.FindComponent('BleDeviceControl1') as
      TLazBleDeviceControl;

    AssertSame(LoadedClient, LoadedControl.Client);
    AssertEquals('streamed-device', LoadedControl.DeviceText);
    AssertFalse(LoadedControl.ShowSelectButton);
    AssertFalse(LoadedControl.ShowConnectionButton);
    AssertEquals('Choose', LoadedControl.SelectButtonCaption);
    AssertEquals('Open', LoadedControl.ConnectButtonCaption);
    AssertEquals('Close', LoadedControl.DisconnectButtonCaption);
    AssertNull(LoadedClient.CoreClient);
    AssertEquals(0, BackendObject.CommandCount);
  finally
    Stream.Free;
    LoadedOwner.Free;
    Owner.Free;
    DeviceControlStreamingBackend := nil;
    Backend := nil;
  end;
end;

procedure TLazBleDeviceControlTest.SelectingDeviceUpdatesExistingClientWithoutConnecting;
begin
  FControl.Client := FClient;
  FControl.SelectionResult := True;
  FControl.SelectedDevice := Device('device-a', 'Timing unit', -45);

  FControl.SelectDevice;

  AssertEquals('device-a', FClient.DeviceId);
  AssertEquals('Timing unit', FClient.DeviceName);
  AssertEquals('Timing unit', FControl.DeviceText);
  AssertTrue(FControl.CanToggleConnection);
  AssertEquals(0, FBackendObject.CommandCount);
  AssertNull(FClient.CoreClient);
end;

procedure TLazBleDeviceControlTest.DirectClientSelectionRefreshesControl;
begin
  FControl.Client := FClient;

  FClient.SelectDevice(Device('device-b', 'Direct selection', -52));

  AssertEquals('Direct selection', FControl.DeviceText);
  AssertTrue(FControl.CanToggleConnection);
end;

procedure TLazBleDeviceControlTest.ConnectActionUsesBoundClient;
begin
  FClient.SelectDevice(Device('device-a', 'Timing unit', -45));
  FControl.Client := FClient;

  FControl.ToggleConnection;
  CheckSynchronize;

  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckConnect), Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('device-a', FBackendObject.Commands[0].DeviceId);
  AssertEquals(Ord(lbcstConnecting), Ord(FClient.State));
  AssertTrue(FControl.CanToggleConnection);
end;

procedure TLazBleDeviceControlTest.ConnectActionRetriesAfterError;
var
  OperationId: TBleOperationId;
begin
  FClient.SelectDevice(Device('device-a', 'Timing unit', -45));
  FControl.Client := FClient;
  FControl.ToggleConnection;
  OperationId := FBackendObject.OperationIds[0];
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationFailed, 42, 'connection failed'));
  CheckSynchronize;
  AssertEquals(Ord(lbcstError), Ord(FClient.State));

  FControl.ToggleConnection;
  CheckSynchronize;

  AssertEquals(2, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckConnect), Ord(FBackendObject.Commands[1].Kind));
  AssertEquals(Ord(lbcstConnecting), Ord(FClient.State));
end;

procedure TLazBleDeviceControlTest.
  StatusTextReflectsClientScanAndAvailabilityStates;
var
  DisconnectedText, ConnectingText, ScanningText, AvailabilityText: string;
begin
  FClient.SelectDevice(Device('device-a', 'Timing unit', -45));
  FControl.Client := FClient;

  AssertEquals(LazBleDeviceText(FClient), FControl.DeviceText);
  DisconnectedText := LazBleStatusText(FClient);
  AssertEquals(DisconnectedText, FControl.StatusText);

  FControl.ToggleConnection;
  ConnectingText := LazBleStatusText(FClient);
  AssertTrue(ConnectingText <> DisconnectedText);
  AssertEquals(ConnectingText, FControl.StatusText);

  FLazBle.StartScan;
  ScanningText := LazBleStatusText(FClient);
  AssertTrue(ScanningText <> ConnectingText);
  AssertEquals(ScanningText, FControl.StatusText);

  FLazBle.RefreshAvailability;
  AvailabilityText := LazBleStatusText(FClient);
  AssertTrue(AvailabilityText <> ScanningText);
  AssertEquals(AvailabilityText, FControl.StatusText);
end;

procedure TLazBleDeviceControlTest.DestroyedClientClearsBinding;
begin
  FControl.Client := FClient;

  FClient.Free;
  FClient := nil;

  AssertNull(FControl.Client);
  AssertFalse(FControl.CanSelectDevice);
  AssertFalse(FControl.CanToggleConnection);
end;

procedure TLazBleDeviceControlTest.RebindingStopsObservingPreviousClient;
var
  OtherClient: TLazBleLclClient;
begin
  OtherClient := TLazBleLclClient.Create(nil);
  try
    OtherClient.LazBle := FLazBle;
    FControl.Client := FClient;
    FControl.Client := OtherClient;

    FClient.SelectDevice(Device('old-device', 'Old device', -70));
    AssertTrue(FControl.DeviceText <> 'Old device');

    OtherClient.SelectDevice(Device('new-device', 'New device', -40));
    AssertEquals('New device', FControl.DeviceText);
  finally
    OtherClient.Free;
  end;
end;

initialization
  RegisterClass(TDeviceControlStreamingOwner);
  RegisterClass(TDeviceControlStreamingLazBle);
  RegisterTest(TLazBleDeviceControlTest);

finalization
  UnregisterClass(TDeviceControlStreamingLazBle);
  UnregisterClass(TDeviceControlStreamingOwner);

end.
