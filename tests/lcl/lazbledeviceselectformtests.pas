unit LazBleDeviceSelectFormTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  FpcUnit,
  TestRegistry,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleLclScan,
  LazBleDeviceSelectForm,
  FakeLazBleBackend;

type
  TBleDeviceSelectFormTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FForm: TBleDeviceSelectForm;
    FForwardedResultCount: Integer;
    procedure ForwardedResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure EmitResult(const AOperationId: TBleOperationId;
      const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure BindingDoesNotStartBleOperation;
    procedure StartScanUsesConfiguredAdapterAndTimeout;
    procedure ResultsKeepDiscoveryOrderAndUpdateExistingDevice;
    procedure SelectedDeviceUsesStableSnapshotIndex;
    procedure StopScanCancelsActiveOperation;
    procedure StartScanStartsFreshScanAfterCompletion;
    procedure ExistingScanHandlerIsForwardedAndRestored;
  end;

implementation

procedure TBleDeviceSelectFormTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FBle := TLazBle.Create(FBackend);
  FScan := TLazBleLclScan.Create(FBle);
  FForm := TBleDeviceSelectForm.Create(nil, FScan);
  FForwardedResultCount := 0;
end;

procedure TBleDeviceSelectFormTest.TearDown;
begin
  FForm.Free;
  FScan.Free;
  FBle.Free;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TBleDeviceSelectFormTest.ForwardedResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
begin
  Inc(FForwardedResultCount);
end;

procedure TBleDeviceSelectFormTest.EmitResult(
  const AOperationId: TBleOperationId; const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekScanResult;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := ADeviceId;
  BackendEvent.DeviceName := ADeviceName;
  BackendEvent.Rssi := ARssi;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  CheckSynchronize;
end;

procedure TBleDeviceSelectFormTest.BindingDoesNotStartBleOperation;
begin
  AssertEquals(0, FBackendObject.CommandCount);
  AssertEquals(0, FForm.DeviceCount);
end;

procedure TBleDeviceSelectFormTest.StartScanUsesConfiguredAdapterAndTimeout;
begin
  FForm.AdapterId := 'hci-test';
  FForm.ScanTimeoutMs := 4321;

  FForm.StartScan;

  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckStartScan), Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('hci-test', FBackendObject.Commands[0].AdapterId);
  AssertEquals(4321, Integer(FBackendObject.Commands[0].TimeoutMs));
  AssertEquals(Ord(lblssScanning), Ord(FForm.ScanState));
end;

procedure TBleDeviceSelectFormTest.ResultsKeepDiscoveryOrderAndUpdateExistingDevice;
var
  OperationId: TBleOperationId;
begin
  FForm.StartScan;
  OperationId := FBackendObject.OperationIds[0];

  EmitResult(OperationId, 'device-a', 'First', -70);
  EmitResult(OperationId, 'device-b', 'Second', -50);
  EmitResult(OperationId, 'device-a', 'First updated', -40);

  AssertEquals(2, FForm.DeviceCount);
  AssertEquals('device-a', FForm.Devices[0].DeviceId);
  AssertEquals('First updated', FForm.Devices[0].DeviceName);
  AssertEquals(-40, FForm.Devices[0].Rssi);
  AssertEquals('device-b', FForm.Devices[1].DeviceId);
end;

procedure TBleDeviceSelectFormTest.SelectedDeviceUsesStableSnapshotIndex;
var
  Device: TBleDeviceInfo;
  OperationId: TBleOperationId;
begin
  FForm.StartScan;
  OperationId := FBackendObject.OperationIds[0];
  EmitResult(OperationId, 'device-a', 'First', -70);
  EmitResult(OperationId, 'device-b', 'Second', -50);

  FForm.SelectedIndex := 1;

  AssertTrue(FForm.TryGetSelectedDevice(Device));
  AssertEquals('device-b', Device.DeviceId);
  AssertEquals('Second', Device.DeviceName);
  AssertEquals(-50, Device.Rssi);
end;

procedure TBleDeviceSelectFormTest.StopScanCancelsActiveOperation;
var
  OperationId: TBleOperationId;
begin
  FForm.StartScan;
  OperationId := FBackendObject.OperationIds[0];

  FForm.StopScan;

  AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
end;

procedure TBleDeviceSelectFormTest.StartScanStartsFreshScanAfterCompletion;
var
  FirstOperationId: TBleOperationId;
begin
  FForm.StartScan;
  FirstOperationId := FBackendObject.OperationIds[0];
  EmitResult(FirstOperationId, 'device-a', 'First', -70);
  AssertTrue(FBackendObject.CompleteOperation(FirstOperationId,
    lbekOperationSucceeded));
  CheckSynchronize;
  AssertEquals(1, FForm.DeviceCount);

  FForm.StartScan;

  AssertEquals(2, FBackendObject.CommandCount);
  AssertEquals(0, FForm.DeviceCount);
  AssertEquals(Ord(lblssScanning), Ord(FForm.ScanState));
end;

procedure TBleDeviceSelectFormTest.ExistingScanHandlerIsForwardedAndRestored;
var
  OperationId: TBleOperationId;
begin
  FForm.Free;
  FForm := nil;
  FScan.OnResult := @ForwardedResult;
  FForm := TBleDeviceSelectForm.Create(nil, FScan);
  FForm.StartScan;
  OperationId := FBackendObject.OperationIds[0];

  EmitResult(OperationId, 'device-a', 'First', -70);
  AssertEquals(1, FForwardedResultCount);
  AssertEquals(1, FForm.DeviceCount);

  FBackendObject.CompleteOperation(OperationId, lbekOperationSucceeded);
  CheckSynchronize;
  FForm.Free;
  FForm := nil;
  FScan.Start('', 1000);
  OperationId := FBackendObject.OperationIds[1];
  EmitResult(OperationId, 'device-b', 'Second', -60);

  AssertEquals(2, FForwardedResultCount);
end;

initialization
  RegisterTest(TBleDeviceSelectFormTest);

end.
