unit LazBleLclContractTests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FpcUnit, TestRegistry, LazBleTypes, LazBleBackend,
  LazBleOperation, LazBleClient, LazBleComponent, LazBleLclScan,
  FakeLazBleBackend;

type
  TLazBleLclContractTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FFake: TFakeLazBleBackend;
    FRoot: TLazBleComponent;
    FClient: TLazBleLclClient;
    FClientToRemove: TLazBleLclClient;
    FCount: Integer;
    FRestartScan: Boolean;
    FUnconfiguredClient: TBleClient;
    procedure ScanResult(Sender: TObject; const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt);
    procedure ScanState(Sender: TObject; const AState: TLazBleLclScanState);
    procedure ScanCompleted(Sender: TObject; const AState: TLazBleLclScanState);
    procedure Unconfigure(Sender: TObject);
    procedure RemoveOtherClient(Sender: TObject);
    procedure Connected(Sender: TObject);
    procedure DisconnectingState(Sender: TObject; const AState: TLazBleClientState);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ScanResultIsDeliveredBeforeBackendReturns;
    procedure NewScanFromStateHandlerSuppressesOldCompletion;
    procedure ShutdownExposesPendingOperationAndNativeZeroFailure;
    procedure UnconfigureRunsBeforeCoreClientRemoval;
    procedure RootShutdownUnconfiguresOnceBeforeCompletion;
    procedure ConnectCompletionCanStartDisconnect;
    procedure ConnectingStateCanStartDisconnect;
    procedure UnconfigureCanRemoveAnotherClient;
  end;

implementation

procedure TLazBleLclContractTest.SetUp;
begin
  inherited SetUp;
  FFake := TFakeLazBleBackend.Create;
  FBackend := FFake;
  FRoot := TLazBleComponent.Create(nil, FBackend);
  FClient := FRoot.CreateClient('device-a');
  FCount := 0;
  FRestartScan := False;
end;

procedure TLazBleLclContractTest.TearDown;
var
  Index: Integer;
begin
  FRoot.ShutdownAsync;
  for Index := 0 to FFake.CommandCount - 1 do
    FFake.CompleteOperation(FFake.OperationIds[Index], lbekOperationCancelled);
  FFake.CompleteShutdown;
  FRoot.Free;
  FBackend := nil;
  inherited TearDown;
end;

procedure TLazBleLclContractTest.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
begin
  AssertEquals(Int64(MainThreadID), Int64(GetCurrentThreadID));
  Inc(FCount);
end;

procedure TLazBleLclContractTest.ScanState(Sender: TObject;
  const AState: TLazBleLclScanState);
begin
  if FRestartScan and (AState = lblssSucceeded) then
  begin
    FRestartScan := False;
    FRoot.StartScan;
  end;
end;

procedure TLazBleLclContractTest.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
begin
  Inc(FCount);
end;

procedure TLazBleLclContractTest.Unconfigure(Sender: TObject);
begin
  FUnconfiguredClient := FClient.CoreClient;
  AssertNotNull(FUnconfiguredClient);
  AssertSame(FUnconfiguredClient, FRoot.Facade.FindClient('device-a'));
  AssertEquals('device-a', FUnconfiguredClient.DeviceId);
  Inc(FCount);
end;

procedure TLazBleLclContractTest.RemoveOtherClient(Sender: TObject);
begin
  FRoot.RemoveClient(FClientToRemove);
  FClientToRemove := nil;
end;

procedure TLazBleLclContractTest.UnconfigureCanRemoveAnotherClient;
begin
  FClientToRemove := FRoot.CreateClient('device-b');
  FClient.Connect;
  FClient.OnUnconfigureClient := @RemoveOtherClient;
  FRoot.ShutdownAsync;
  AssertEquals(1, FRoot.ClientCount);
  AssertNull(FClientToRemove);
end;

procedure TLazBleLclContractTest.Connected(Sender: TObject);
begin
  Inc(FCount);
  FClient.Disconnect;
end;

procedure TLazBleLclContractTest.DisconnectingState(Sender: TObject;
  const AState: TLazBleClientState);
begin
  if AState = lbcstConnecting then FClient.Disconnect;
end;

procedure TLazBleLclContractTest.ScanResultIsDeliveredBeforeBackendReturns;
var
  Event: TLazBleBackendEvent;
begin
  FRoot.OnScanResult := @ScanResult;
  FRoot.StartScan;
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekScanResult;
  Event.OperationId := FFake.OperationIds[0];
  Event.DeviceId := 'found';
  AssertTrue(FFake.EmitProgress(Event));
  AssertEquals(1, FCount);
  AssertEquals(1, Length(FRoot.ScanResults));
end;

procedure TLazBleLclContractTest.NewScanFromStateHandlerSuppressesOldCompletion;
begin
  FRoot.OnScanStateChanged := @ScanState;
  FRoot.OnScanCompleted := @ScanCompleted;
  FRoot.StartScan;
  FRestartScan := True;
  AssertTrue(FFake.CompleteOperation(FFake.OperationIds[0], lbekOperationSucceeded));
  AssertEquals(Ord(lblssScanning), Ord(FRoot.ScanState));
  AssertEquals(0, FCount);
  AssertTrue(FFake.CompleteOperation(FFake.OperationIds[1], lbekOperationSucceeded));
  AssertEquals(1, FCount);
end;

procedure TLazBleLclContractTest.ShutdownExposesPendingOperationAndNativeZeroFailure;
var
  Operation: IBleOperation;
begin
  FRoot.StartScan;
  Operation := FRoot.ShutdownAsync;
  AssertTrue(Operation = FRoot.ShutdownAsync);
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FFake.CompleteOperation(FFake.OperationIds[0], lbekOperationCancelled));
  AssertTrue(FFake.CompleteShutdown(0, '', True));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(0, Operation.ErrorCode);
  AssertEquals('', Operation.ErrorMessage);
end;

procedure TLazBleLclContractTest.UnconfigureRunsBeforeCoreClientRemoval;
begin
  FClient.OnUnconfigureClient := @Unconfigure;
  FClient.Connect;
  AssertTrue(FFake.CompleteOperation(FFake.OperationIds[0], lbekOperationCancelled));
  FClient.DeviceId := 'device-b';
  AssertEquals(1, FCount);
  AssertNull(FClient.CoreClient);
  AssertNull(FRoot.Facade.FindClient('device-a'));
end;

procedure TLazBleLclContractTest.RootShutdownUnconfiguresOnceBeforeCompletion;
var
  Operation: IBleOperation;
begin
  FClient.OnUnconfigureClient := @Unconfigure;
  FClient.Connect;
  Operation := FRoot.ShutdownAsync;
  AssertEquals(1, FCount);
  AssertNull(FClient.CoreClient);
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  FRoot.ShutdownAsync;
  AssertEquals(1, FCount);
end;

procedure TLazBleLclContractTest.ConnectCompletionCanStartDisconnect;
var
  Event: TLazBleBackendEvent;
begin
  FClient.OnConnected := @Connected;
  FClient.Connect;
  Event := Default(TLazBleBackendEvent);
  Event.Kind := lbekConnected;
  Event.OperationId := FFake.OperationIds[0];
  Event.DeviceId := 'device-a';
  Event.Generation := FFake.Commands[0].Generation;
  AssertTrue(FFake.EmitProgress(Event));
  AssertTrue(FFake.CompleteOperation(Event.OperationId, lbekOperationSucceeded));
  Event.Kind := lbekServicesDiscovered;
  Event.OperationId := FFake.OperationIds[1];
  AssertTrue(FFake.EmitProgress(Event));
  AssertTrue(FFake.CompleteOperation(Event.OperationId, lbekOperationSucceeded));
  AssertEquals(1, FCount);
  AssertEquals(Ord(lbckDisconnect), Ord(FFake.Commands[2].Kind));
  Event.Kind := lbekDisconnected;
  Event.OperationId := FFake.OperationIds[2];
  AssertTrue(FFake.EmitProgress(Event));
  AssertTrue(FFake.CompleteOperation(Event.OperationId, lbekOperationSucceeded));
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
end;

procedure TLazBleLclContractTest.ConnectingStateCanStartDisconnect;
begin
  FClient.OnStateChanged := @DisconnectingState;
  FClient.Connect;
  AssertEquals(0, FFake.CommandCount);
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
end;

initialization
  RegisterTest(TLazBleLclContractTest);
end.
