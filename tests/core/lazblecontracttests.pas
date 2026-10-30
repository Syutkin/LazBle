unit LazBleContractTests;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, fpcunit, testregistry, LazBleTypes, LazBleBackend,
  LazBleOperation, LazBleGattOperation, LazBleGattSubscription, LazBleGattProfile,
  LazBleClient, LazBleFacade, LazBleSync, FakeLazBleBackend;

type
  TFakeBackendWithLifetime = class(TFakeLazBleBackend)
  public
    Destroyed: PBoolean;
    destructor Destroy; override;
  end;

  TCleanupProfile = class(TBleGattProfile)
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    Token: IBleSubscription;
    Cleanup: IBleGattOperation;
  end;

  TAdmissionProfile = class(TBleGattProfile)
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    Ble: TLazBle;
    Client: TBleClient;
    ProbeClosing: Boolean;
    Rejected: Integer;
    OnDetachProbe: TNotifyEvent;
  end;

  TDeferredProfile = class(TBleGattProfile)
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    procedure ReadyNow;
  end;

  TLazBleContractTest = class(TTestCase)
  private
    FBle: TLazBle;
    FBackend: ILazBleBackend;
    FFake: TFakeLazBleBackend;
    FClient: TBleClient;
    FValues: Integer;
    FCallbackErrors: Integer;
    FNextOperation: IBleOperation;
    FNextRead: IBleGattOperation;
    procedure DisconnectWhenConnected(Sender: TObject);
    procedure RestartWhenDisconnected(Sender: TObject);
    procedure TryReadAfterUnsubscribeFailure(Sender: TObject);
    procedure ShutdownWhenReadCompletes(Sender: TObject);
    procedure Emit(Kind: TLazBleBackendEventKind; Id: TBleOperationId;
      Token: TBleSubscriptionId = 0);
    procedure Connect;
    function LastId: TBleOperationId;
    procedure Data(Sender: TObject; const Value: TBytes);
    procedure ScanData(Sender: TObject; const DeviceId, DeviceName: string;
      const Rssi: SmallInt);
    procedure RaisingScanData(Sender: TObject; const DeviceId, DeviceName: string;
      const Rssi: SmallInt);
    procedure CallbackError(Sender: TObject);
    procedure AvailabilityCompletedWithDiagnostic(Sender: TObject);
    procedure LateOwnerCompletion(Sender: TObject);
    procedure EmitClosingNotification(Sender: TObject);
    procedure ObserveSessionClosing(Sender: TObject; const State: TLazBleClientState);
    procedure RaiseWhenSessionCloses(Sender: TObject; const State: TLazBleClientState);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure QueuedConnectCancelUsesBackendOutcome;
    procedure StartedConnectCancelDoesNotDisconnect;
    procedure CancelDuringProfileAttachDoesNotRollBack;
    procedure DiscoveryCancellationKeepsPhysicalConnectionExplicit;
    procedure ReadCancelKeepsSuccessfulValue;
    procedure ReadCancelKeepsNativeFailureZero;
    procedure AvailabilityCancelDoesNotHideFailureZero;
    procedure AvailabilityCancelCanStillSucceed;
    procedure ShutdownKeepsAvailabilityUnavailable;
    procedure ShutdownPreservesCleanupFailureZero;
    procedure ShutdownFailureDoesNotDependOnCodeOrText;
    procedure PendingUnsubscribeWaitsForCancelledNotify;
    procedure PendingUnsubscribeCleansSuccessfulNotify;
    procedure FailedUnsubscribeRetiresTokenAndDisconnects;
    procedure EarlyNotificationIsDropped;
    procedure CoreRejectsForeignThread;
    procedure SyncDeadlineDoesNotCancelOperation;
    procedure PendingOperationOutlivesDestroyedOwner;
    procedure ConnectCompletionCanStartDisconnect;
    procedure DisconnectCompletionCanStartNewConnect;
    procedure UnsubscribeFailureBlocksReentrantRead;
    procedure ShutdownPreservesStartedReadValue;
    procedure ShutdownDoesNotActivatePendingSubscription;
    procedure UnsubscribeRecoveryRetainsReconnectPolicy;
    procedure DisconnectDoesNotInventGattCancellation;
    procedure OldGenerationReadRetainsActualValue;
    procedure UnsubscribeResultSurvivesDisconnectAndDroppedToken;
    procedure OldUnsubscribeFailureDoesNotDisconnectNewSession;
    procedure DisconnectCancellationKeepsCleanup;
    procedure DisconnectCancellationDoesNotRestorePartialConnect;
    procedure QueuedCancelCompletionCanStartNextConnect;
    procedure TwoClientsKeepReadResultsWhenCompletedOutOfOrder;
    procedure ReadCompletionCanBeginShutdown;
    procedure SubscriptionRegistrationCompletesDirectly;
    procedure ConnectedEventDoesNotReplaceNativeOutcome;
    procedure ServicesSnapshotWaitsForNativeOutcome;
    procedure DisconnectedEventDoesNotReplaceNativeOutcome;
    procedure LateDisconnectOutcomeDoesNotChangeNewConnection;
    procedure ScanFinalSnapshotCompletesDirectly;
    procedure AvailabilityResultCompletesDirectly;
    procedure ShutdownScanKeepsSnapshotWithoutDeliveringResults;
    procedure ScanResultExceptionDoesNotLoseSnapshotOrCompletion;
    procedure RemovedClientDoesNotLoseAcceptedRead;
    procedure ActiveScanAndAvailabilityKeepTheirIdentityAndExcludeEachOther;
    procedure GattIsAcceptedDuringScan;
    procedure ShutdownRemainsPendingWhileClientsClose;
    procedure ShutdownRejectsReentrantWorkFromProfileDetach;
    procedure ShutdownStillAcceptsProfileUnsubscribeCleanup;
    procedure DestroyedFacadeIgnoresLateAvailabilityAndShutdown;
    procedure ShutdownClosesDataBeforeProfileDetach;
    procedure FacadeRetainsBackendAfterShutdownUntilRelease;
    procedure ReconnectedClientIgnoresOldPhysicalLinkEvents;
    procedure ShutdownKeepsNativeFailureWhenClosingCallbackRaises;
  end;

implementation

procedure TLazBleContractTest.RaiseWhenSessionCloses(Sender: TObject;
  const State: TLazBleClientState);
begin
  if State <> lbcstDisconnected then Exit;
  AssertEquals(Ord(lbopPending), Ord(FNextOperation.State));
  raise Exception.Create('test closing callback');
end;

procedure TLazBleContractTest.ShutdownKeepsNativeFailureWhenClosingCallbackRaises;
var Other: TBleClient; Connected: IBleOperation; Id: TBleOperationId;
  E: TLazBleBackendEvent; Previous: TNotifyEvent;
begin
  Connect;
  Other := FBle.CreateClient('other'); Connected := Other.ConnectAsync; Id := LastId;
  E := Default(TLazBleBackendEvent); E.DeviceId := 'other';
  E.Kind := lbekConnected; E.OperationId := Id; FFake.EmitProgress(E);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  E.Kind := lbekServicesDiscovered; E.OperationId := LastId;
  FFake.EmitProgress(E); FFake.CompleteOperation(E.OperationId, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Connected.State));
  FClient.OnStateChanged := @RaiseWhenSessionCloses;
  Other.OnStateChanged := @ObserveSessionClosing;
  FNextOperation := FBle.ShutdownAsync;
  Previous := ApplicationHandleException; ApplicationHandleException := @CallbackError;
  try AssertTrue(FFake.CompleteShutdown(0, '', True));
  finally ApplicationHandleException := Previous; end;
  AssertEquals(1, FCallbackErrors); AssertEquals(1, FValues);
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
  AssertEquals(Ord(lbcstDisconnected), Ord(Other.State));
  AssertEquals(Ord(lbopFailed), Ord(FNextOperation.State));
  AssertEquals(0, FNextOperation.ErrorCode); AssertEquals('', FNextOperation.ErrorMessage);
  AssertTrue(FNextOperation = FBle.ShutdownAsync);
end;

destructor TFakeBackendWithLifetime.Destroy;
begin
  if Destroyed <> nil then Destroyed^ := True;
  inherited Destroy;
end;

procedure TLazBleContractTest.FacadeRetainsBackendAfterShutdownUntilRelease;
var Backend: ILazBleBackend; Fake: TFakeBackendWithLifetime;
  Ble: TLazBle; Shutdown: IBleOperation; Destroyed: Boolean;
begin
  Destroyed := False;
  Fake := TFakeBackendWithLifetime.Create; Fake.Destroyed := @Destroyed;
  Backend := Fake; Ble := TLazBle.Create(Backend);
  try
    Shutdown := Ble.ShutdownAsync;
    AssertTrue(Fake.CompleteShutdown);
    AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
    Backend := nil;
    AssertFalse(Destroyed);
    FreeAndNil(Ble);
    AssertTrue(Destroyed);
  finally Ble.Free; Backend := nil; end;
end;

procedure TLazBleContractTest.ReconnectedClientIgnoresOldPhysicalLinkEvents;
var Connection, Disconnection: IBleOperation; Id: TBleOperationId;
  E: TLazBleBackendEvent;
begin
  Connect;
  Disconnection := FClient.DisconnectAsync; Id := LastId;
  Emit(lbekDisconnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Disconnection.State));
  Connection := FClient.ConnectAsync; Id := LastId;
  E := Default(TLazBleBackendEvent); E.DeviceId := 'peer';
  E.OperationId := Id; E.Generation := 1;
  E.Kind := lbekConnected; AssertTrue(FFake.EmitProgress(E));
  E.Kind := lbekDisconnected; AssertTrue(FFake.EmitProgress(E));
  AssertEquals(Ord(lbcstConnecting), Ord(FClient.State));
  AssertEquals(Ord(lbopPending), Ord(Connection.State));
  AssertEquals('Old link events do not start discovery', 4, FFake.CommandCount);
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Connection.State));
end;

procedure TLazBleContractTest.EmitClosingNotification(Sender: TObject);
begin Emit(lbekNotification, 0, 7); end;

procedure TLazBleContractTest.ShutdownClosesDataBeforeProfileDetach;
var Profile: TAdmissionProfile; Token: IBleSubscription; Shutdown: IBleOperation;
begin
  Profile := TAdmissionProfile.Create; FClient.AddProfile(Profile);
  Connect;
  Token := FClient.SubscribeAsync('service', 'notify');
  Emit(lbekSubscribed, LastId, 7); FFake.CompleteOperation(LastId, lbekOperationSucceeded);
  Token.OnData := @Data;
  Profile.OnDetachProbe := @EmitClosingNotification;
  Shutdown := FBle.ShutdownAsync;
  AssertEquals(0, FValues);
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
end;

procedure TCleanupProfile.DoAttach;
begin MarkReady; end;

procedure TCleanupProfile.DoDetach;
begin
  if Token <> nil then Cleanup := Token.Unsubscribe;
end;

procedure TLazBleContractTest.ShutdownStillAcceptsProfileUnsubscribeCleanup;
var Profile: TCleanupProfile; Shutdown: IBleOperation; Id: TBleOperationId;
begin
  Profile := TCleanupProfile.Create; FClient.AddProfile(Profile);
  Connect;
  Profile.Token := FClient.SubscribeAsync('service', 'notify');
  Emit(lbekSubscribed, LastId, 7); FFake.CompleteOperation(LastId, lbekOperationSucceeded);
  Shutdown := FBle.ShutdownAsync;
  AssertTrue(Profile.Cleanup <> nil);
  AssertEquals(Ord(lbopPending), Ord(Profile.Cleanup.State));
  AssertEquals(Ord(lbckUnsubscribe), Ord(FFake.Commands[3].Kind));
  Id := LastId;
  AssertTrue(FFake.CompleteOperation(Id, lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Profile.Cleanup.State));
  AssertEquals('Shutdown does not submit a compensating disconnect', 4, FFake.CommandCount);
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
end;

procedure TLazBleContractTest.LateOwnerCompletion(Sender: TObject);
begin Inc(FValues); end;

procedure TLazBleContractTest.DestroyedFacadeIgnoresLateAvailabilityAndShutdown;
var AvailabilityOp: IBleAvailabilityOperation; Shutdown: IBleOperation;
  Id: TBleOperationId; R: TLazBleRequestResult;
begin
  AvailabilityOp := FBle.CheckAvailabilityAsync(''); Id := LastId;
  AvailabilityOp.OnCompleted := @LateOwnerCompletion;
  Shutdown := FBle.ShutdownAsync; Shutdown.OnCompleted := @LateOwnerCompletion;
  FreeAndNil(FBle);
  AssertEquals(Ord(lbopCancelled), Ord(AvailabilityOp.State));
  AssertEquals(Ord(lbopCancelled), Ord(Shutdown.State));
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded; R.Availability := lbaAvailable;
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(0, FValues);
  AssertEquals(Ord(lbopCancelled), Ord(Shutdown.State));
end;

procedure TLazBleContractTest.AvailabilityCompletedWithDiagnostic(Sender: TObject);
begin
  AssertEquals(Ord(lbaAvailable), Ord(FBle.DiagnosticInfo.Availability));
  AssertEquals('adapter', FBle.DiagnosticInfo.AdapterId);
  AssertEquals('native', FBle.DiagnosticInfo.NativeVersion);
  Inc(FValues);
end;

procedure TAdmissionProfile.DoAttach;
begin MarkReady; end;

procedure TAdmissionProfile.DoDetach;
var ReadOp: IBleGattOperation; Scan: IBleScanOperation;
  Availability: IBleAvailabilityOperation;
  ConnectOp: IBleOperation;
begin
  if Assigned(OnDetachProbe) then OnDetachProbe(Self);
  if not ProbeClosing then Exit;
  ReadOp := Client.ReadAsync('service', 'value');
  if ReadOp.State = lbopFailed then Inc(Rejected);
  try Ble.CreateClient('during-close');
  except on E: EInvalidOperation do Inc(Rejected); end;
  Scan := Ble.ScanAsync('', 0);
  if Scan.State = lbopFailed then Inc(Rejected);
  Availability := Ble.CheckAvailabilityAsync('');
  if Availability.State = lbopFailed then Inc(Rejected);
  ConnectOp := Client.ConnectAsync;
  if ConnectOp.State = lbopFailed then Inc(Rejected);
end;

procedure TLazBleContractTest.ShutdownRejectsReentrantWorkFromProfileDetach;
var Profile: TAdmissionProfile; Shutdown: IBleOperation;
  Other: TBleClient; Connected: IBleOperation; Id: TBleOperationId;
  E: TLazBleBackendEvent;
begin
  Profile := TAdmissionProfile.Create;
  Profile.Ble := FBle; Profile.Client := FClient;
  FClient.AddProfile(Profile);
  Connect;
  Other := FBle.CreateClient('other'); Connected := Other.ConnectAsync;
  Id := LastId;
  E := Default(TLazBleBackendEvent); E.DeviceId := 'other';
  E.Kind := lbekConnected; E.OperationId := Id; FFake.EmitProgress(E);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  E.Kind := lbekServicesDiscovered; E.OperationId := LastId;
  FFake.EmitProgress(E); FFake.CompleteOperation(E.OperationId, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Connected.State));
  Profile.Client := Other;
  Profile.ProbeClosing := True;
  Shutdown := FBle.ShutdownAsync;
  Profile.ProbeClosing := False;
  AssertEquals(5, Profile.Rejected);
  AssertEquals('No new commands are accepted from closing callbacks', 4, FFake.CommandCount);
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
end;

procedure TLazBleContractTest.RemovedClientDoesNotLoseAcceptedRead;
var ReadOp: IBleGattOperation; ReadId: TBleOperationId; R: TLazBleRequestResult;
begin
  Connect;
  ReadOp := FClient.ReadAsync('service', 'value'); ReadId := LastId;
  Emit(lbekDisconnected, 0);
  FBle.RemoveClient(FClient); FClient := nil;
  AssertEquals(Ord(lbopPending), Ord(ReadOp.State));
  FClient := FBle.CreateClient('peer');
  Connect;
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  R.Value := TBytes.Create(91);
  AssertTrue(FFake.FinishRequest(ReadId, R));
  AssertEquals(Ord(lbopSucceeded), Ord(ReadOp.State));
  AssertEquals(91, ReadOp.Value[0]);
  AssertEquals(Ord(lbcstReady), Ord(FClient.State));
  AssertTrue('The retained session advances its generation', FFake.Commands[3].Generation > 1);
end;

procedure TLazBleContractTest.ActiveScanAndAvailabilityKeepTheirIdentityAndExcludeEachOther;
var Scan: IBleScanOperation; Availability: IBleAvailabilityOperation;
  R: TLazBleRequestResult;
begin
  Scan := FBle.ScanAsync('', 0);
  AssertTrue(Scan = FBle.ScanAsync('another', 10));
  Availability := FBle.CheckAvailabilityAsync('');
  AssertEquals(Ord(lbopFailed), Ord(Availability.State));
  AssertEquals(1, FFake.CommandCount);
  AssertTrue(FFake.CompleteOperation(LastId, lbekOperationSucceeded));
  Availability := FBle.CheckAvailabilityAsync('');
  AssertTrue(Availability = FBle.CheckAvailabilityAsync('another'));
  Scan := FBle.ScanAsync('', 10);
  AssertEquals(Ord(lbopFailed), Ord(Scan.State));
  AssertEquals(2, FFake.CommandCount);
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  R.Availability := lbaAvailable;
  AssertTrue(FFake.FinishRequest(LastId, R));
  AssertEquals(Ord(lbopSucceeded), Ord(Availability.State));
end;

procedure TLazBleContractTest.GattIsAcceptedDuringScan;
var Scan: IBleScanOperation; ReadOp: IBleGattOperation;
begin
  Connect;
  Scan := FBle.ScanAsync('', 0);
  ReadOp := FClient.ReadAsync('service', 'value');
  AssertEquals(Ord(lbopPending), Ord(Scan.State));
  AssertEquals(Ord(lbopPending), Ord(ReadOp.State));
  AssertEquals(Ord(lbckRead), Ord(FFake.Commands[3].Kind));
end;

procedure TLazBleContractTest.ObserveSessionClosing(Sender: TObject;
  const State: TLazBleClientState);
begin
  if State <> lbcstDisconnected then Exit;
  AssertTrue(FNextOperation <> nil);
  AssertEquals('Shutdown publishes terminal state after session callbacks',
    Ord(lbopPending), Ord(FNextOperation.State));
  Inc(FValues);
end;

procedure TLazBleContractTest.ShutdownRemainsPendingWhileClientsClose;
begin
  Connect;
  FClient.OnStateChanged := @ObserveSessionClosing;
  FNextOperation := FBle.ShutdownAsync;
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(1, FValues);
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
  AssertEquals(Ord(lbopSucceeded), Ord(FNextOperation.State));
end;

procedure TLazBleContractTest.RaisingScanData(Sender: TObject;
  const DeviceId, DeviceName: string; const Rssi: SmallInt);
begin Inc(FValues); raise Exception.Create('test scan handler'); end;

procedure TLazBleContractTest.CallbackError(Sender: TObject);
begin Inc(FCallbackErrors); end;

procedure TLazBleContractTest.ScanResultExceptionDoesNotLoseSnapshotOrCompletion;
var Op: IBleScanOperation; R: TLazBleRequestResult; Previous: TNotifyEvent;
begin
  Op := FBle.ScanAsync('', 0); Op.OnResult := @RaisingScanData;
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  SetLength(R.ScanResults, 2);
  R.ScanResults[0].DeviceId := 'first'; R.ScanResults[1].DeviceId := 'second';
  Previous := ApplicationHandleException;
  ApplicationHandleException := @CallbackError;
  try AssertTrue(FFake.FinishRequest(LastId, R));
  finally ApplicationHandleException := Previous; end;
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(2, Length(Op.Results)); AssertEquals(2, FValues);
  AssertEquals(2, FCallbackErrors);
end;

procedure TLazBleContractTest.ScanData(Sender: TObject;
  const DeviceId, DeviceName: string; const Rssi: SmallInt);
begin Inc(FValues); end;

procedure TLazBleContractTest.ShutdownScanKeepsSnapshotWithoutDeliveringResults;
var Op: IBleScanOperation; Shutdown: IBleOperation;
  R: TLazBleRequestResult; Id: TBleOperationId;
begin
  Op := FBle.ScanAsync('', 0); Id := LastId;
  Op.OnResult := @ScanData;
  Shutdown := FBle.ShutdownAsync;
  R := Default(TLazBleRequestResult); R.Status := lbrsCancelled;
  SetLength(R.ScanResults, 1); R.ScanResults[0].DeviceId := 'final';
  AssertTrue(FFake.FinishRequest(Id, R));
  AssertEquals(0, FValues);
  AssertEquals(1, Length(Op.Results));
  AssertEquals('final', Op.Results[0].DeviceId);
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
end;

procedure TLazBleContractTest.ScanFinalSnapshotCompletesDirectly;
var Op: IBleScanOperation; R: TLazBleRequestResult;
begin
  Op := FBle.ScanAsync('', 0);
  Op.OnResult := @ScanData;
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  SetLength(R.ScanResults, 2);
  R.ScanResults[0].DeviceId := 'first'; R.ScanResults[0].Rssi := -70;
  R.ScanResults[1].DeviceId := 'second'; R.ScanResults[1].Rssi := -40;
  AssertTrue(FFake.FinishRequest(LastId, R));
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(2, Length(Op.Results));
  AssertEquals('first', Op.Results[0].DeviceId);
  AssertEquals('second', Op.Results[1].DeviceId);
  AssertEquals(2, FValues);
end;

procedure TLazBleContractTest.AvailabilityResultCompletesDirectly;
var Op: IBleAvailabilityOperation; R: TLazBleRequestResult;
begin
  Op := FBle.CheckAvailabilityAsync('');
  Op.OnCompleted := @AvailabilityCompletedWithDiagnostic;
  R := Default(TLazBleRequestResult); R.Status := lbrsSucceeded;
  R.Availability := lbaAvailable; R.AdapterId := 'adapter'; R.BackendVersion := 'native';
  AssertTrue(FFake.FinishRequest(LastId, R));
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(Ord(lbaAvailable), Ord(Op.Availability));
  AssertEquals('adapter', FBle.DiagnosticInfo.AdapterId);
  AssertEquals('native', FBle.DiagnosticInfo.NativeVersion);
  AssertEquals(1, FValues);
end;

procedure TLazBleContractTest.LateDisconnectOutcomeDoesNotChangeNewConnection;
var DisconnectOp, ConnectOp: IBleOperation; DisconnectId, Id: TBleOperationId;
begin
  Connect;
  DisconnectOp := FClient.DisconnectAsync; DisconnectId := LastId;
  Emit(lbekDisconnected, DisconnectId);
  ConnectOp := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(ConnectOp.State));
  FFake.CompleteOperation(DisconnectId, lbekOperationFailed, 4, 'old disconnect');
  AssertEquals(Ord(lbopFailed), Ord(DisconnectOp.State));
  AssertEquals(Ord(lbcstReady), Ord(FClient.State));
end;

procedure TLazBleContractTest.ConnectedEventDoesNotReplaceNativeOutcome;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id);
  AssertEquals(1, FFake.CommandCount);
  AssertEquals(Ord(lbopPending), Ord(Op.State));
  FFake.CompleteOperation(Id, lbekOperationFailed, 0, 'connect failed');
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals('connect failed', Op.ErrorMessage);
  AssertEquals(1, FFake.CommandCount);
end;

procedure TLazBleContractTest.ServicesSnapshotWaitsForNativeOutcome;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id);
  AssertEquals(Ord(lbopPending), Ord(Op.State));
  FFake.CompleteOperation(Id, lbekOperationFailed, 4, 'discovery failed');
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals(4, Op.ErrorCode);
end;

procedure TLazBleContractTest.DisconnectedEventDoesNotReplaceNativeOutcome;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Connect; Op := FClient.DisconnectAsync; Id := LastId;
  Emit(lbekDisconnected, Id);
  AssertEquals(Ord(lbopPending), Ord(Op.State));
  FFake.CompleteOperation(Id, lbekOperationFailed, 4, 'disconnect failed');
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals('disconnect failed', Op.ErrorMessage);
end;

procedure TLazBleContractTest.SubscriptionRegistrationCompletesDirectly;
var Token: IBleSubscription; ResultData: TLazBleRequestResult;
begin
  Connect;
  Token := FClient.SubscribeAsync('service', 'notify');
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsSucceeded; ResultData.SubscriptionId := 7;
  AssertTrue(FFake.FinishRequest(LastId, ResultData));
  AssertEquals(Ord(lbsubActive), Ord(Token.State));
  Token.OnData := @Data;
  Emit(lbekNotification, 0, 7);
  AssertEquals(1, FValues);
end;

procedure TLazBleContractTest.ShutdownWhenReadCompletes(Sender: TObject);
begin
  AssertEquals(Ord(lbopSucceeded), Ord(FNextRead.State));
  AssertEquals(42, FNextRead.Value[0]);
  Inc(FValues);
  FNextOperation := FBle.ShutdownAsync;
end;

procedure TLazBleContractTest.TwoClientsKeepReadResultsWhenCompletedOutOfOrder;
var
  Other: TBleClient;
  Connected: IBleOperation;
  First, Second: IBleGattOperation;
  Id, FirstId, SecondId: TBleOperationId;
  E: TLazBleBackendEvent;
  ResultData: TLazBleRequestResult;
begin
  Connect;
  Other := FBle.CreateClient('other');
  Connected := Other.ConnectAsync;
  Id := LastId;
  E := Default(TLazBleBackendEvent);
  E.DeviceId := 'other'; E.OperationId := Id; E.Kind := lbekConnected;
  FFake.EmitProgress(E);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId;
  E.OperationId := Id; E.Kind := lbekServicesDiscovered;
  FFake.EmitProgress(E);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Connected.State));
  First := FClient.ReadAsync('service', 'value'); FirstId := LastId;
  Second := Other.ReadAsync('service', 'value'); SecondId := LastId;
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsSucceeded; ResultData.Value := TBytes.Create(22);
  AssertTrue(FFake.FinishRequest(SecondId, ResultData));
  AssertEquals(Ord(lbopPending), Ord(First.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Second.State));
  AssertEquals(22, Second.Value[0]);
  ResultData.Value := TBytes.Create(11);
  AssertTrue(FFake.FinishRequest(FirstId, ResultData));
  AssertEquals(11, First.Value[0]);
  AssertEquals(22, Second.Value[0]);
end;

procedure TLazBleContractTest.ReadCompletionCanBeginShutdown;
var Id: TBleOperationId;
begin
  Connect;
  FNextRead := FClient.ReadAsync('service', 'value'); Id := LastId;
  FNextRead.OnCompleted := @ShutdownWhenReadCompletes;
  Emit(lbekReadResult, Id);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(1, FValues);
  AssertTrue(FNextOperation <> nil);
  AssertTrue(FFake.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(FNextOperation.State));
end;

type
  TForeignCall = class(TThread)
    Ble: TLazBle;
    Client: TBleClient;
    Operation: IBleOperation;
    Rejected: Integer;
    procedure Execute; override;
  end;

procedure TDeferredProfile.DoAttach;
begin end;
procedure TDeferredProfile.DoDetach;
begin end;
procedure TDeferredProfile.ReadyNow;
begin MarkReady; end;

procedure TForeignCall.Execute;
begin
  try Ble.ScanAsync('', 10); except on E: EInvalidOperation do Inc(Rejected); end;
  try Client.ConnectAsync; except on E: EInvalidOperation do Inc(Rejected); end;
  try Operation.Cancel; except on E: EInvalidOperation do Inc(Rejected); end;
end;

procedure TLazBleContractTest.SetUp;
begin
  FFake := TFakeLazBleBackend.Create; FBackend := FFake;
  FBle := TLazBle.Create(FBackend);
  FClient := FBle.CreateClient('peer');
end;

procedure TLazBleContractTest.TearDown;
begin
  FBle.Free; FBackend := nil;
end;

function TLazBleContractTest.LastId: TBleOperationId;
begin Result := FFake.OperationIds[FFake.CommandCount-1]; end;

procedure TLazBleContractTest.Emit(Kind: TLazBleBackendEventKind;
  Id: TBleOperationId; Token: TBleSubscriptionId);
var E: TLazBleBackendEvent;
begin
  E := Default(TLazBleBackendEvent); E.Kind := Kind; E.OperationId := Id;
  E.DeviceId := 'peer'; E.SubscriptionId := Token; E.Value := TBytes.Create(42);
  if Kind = lbekServicesDiscovered then
  begin
    SetLength(E.Services, 1); E.Services[0].Uuid := 'service';
    SetLength(E.Services[0].Characteristics, 1);
    E.Services[0].Characteristics[0].Uuid := 'notify';
    E.Services[0].Characteristics[0].CanNotify := True;
  end;
  AssertTrue(FFake.EmitProgress(E));
end;

procedure TLazBleContractTest.Connect;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
end;

procedure TLazBleContractTest.Data(Sender: TObject; const Value: TBytes);
begin Inc(FValues); end;

procedure TLazBleContractTest.QueuedConnectCancelUsesBackendOutcome;
var Op: IBleOperation;
begin
  Op := FClient.ConnectAsync; Op.Cancel;
  AssertEquals(Ord(lbopPending), Ord(Op.State));
  AssertEquals(1, FFake.CommandCount);
  AssertTrue(FFake.CancellationWasRequested(LastId));
  FFake.CompleteOperation(LastId, lbekOperationCancelled);
  AssertEquals(Ord(lbopCancelled), Ord(Op.State));
end;

procedure TLazBleContractTest.StartedConnectCancelDoesNotDisconnect;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId; Op.Cancel;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id);
  FFake.CompleteOperation(Id, lbekOperationSucceeded);
  AssertTrue(Op.CancelRequested);
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(Ord(lbcstReady), Ord(FClient.State));
  AssertEquals('No compensating disconnect', 2, FFake.CommandCount);
end;

procedure TLazBleContractTest.CancelDuringProfileAttachDoesNotRollBack;
var Profile: TDeferredProfile; Op: IBleOperation; Id: TBleOperationId;
begin
  Profile := TDeferredProfile.Create; FClient.AddProfile(Profile);
  Op := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id, lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered, Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Op.Cancel;
  AssertEquals(Ord(lbcstAttachingProfiles), Ord(FClient.State));
  Profile.ReadyNow;
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(2, FFake.CommandCount);
end;

procedure TLazBleContractTest.DiscoveryCancellationKeepsPhysicalConnectionExplicit;
var Op, Disconnect: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected, Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Id := LastId; Op.Cancel;
  AssertTrue(FFake.CancellationWasRequested(Id));
  FFake.CompleteOperation(Id,lbekOperationCancelled);
  AssertEquals(Ord(lbopCancelled),Ord(Op.State));
  AssertEquals(Ord(lbcstError),Ord(FClient.State));
  AssertEquals('Native connection is not undone',2,FFake.CommandCount);
  Disconnect := FClient.DisconnectAsync;
  AssertEquals(Ord(lbckDisconnect),Ord(FFake.Commands[2].Kind));
  Emit(lbekDisconnected,LastId); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(Disconnect.State));
end;

procedure TLazBleContractTest.ReadCancelKeepsSuccessfulValue;
var Op: IBleGattOperation;
begin
  Connect; Op := FClient.ReadAsync('service','value'); Op.Cancel;
  Emit(lbekReadResult,LastId); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(Op.State)); AssertEquals(42,Op.Value[0]);
end;

procedure TLazBleContractTest.ReadCancelKeepsNativeFailureZero;
var Op: IBleGattOperation;
begin
  Connect; Op := FClient.ReadAsync('service','value'); Op.Cancel;
  FFake.CompleteOperation(LastId,lbekOperationFailed,0,'invalid native argument');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(0,Op.ErrorCode);
  AssertEquals('invalid native argument',Op.ErrorMessage);
end;

procedure TLazBleContractTest.AvailabilityCancelDoesNotHideFailureZero;
var Op: IBleAvailabilityOperation;
begin
  Op := FBle.CheckAvailabilityAsync(''); Op.Cancel;
  FFake.CompleteOperation(LastId,lbekOperationFailed,0,'native check failed');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(0,Op.ErrorCode);
  AssertEquals(Ord(lbaUnavailable),Ord(FBle.DiagnosticInfo.Availability));
  AssertEquals('native check failed',FBle.DiagnosticInfo.AvailabilityErrorMessage);
end;

procedure TLazBleContractTest.AvailabilityCancelCanStillSucceed;
var Op: IBleAvailabilityOperation; E: TLazBleBackendEvent;
begin
  Op := FBle.CheckAvailabilityAsync(''); Op.Cancel;
  E := Default(TLazBleBackendEvent); E.Kind := lbekAvailabilityResult;
  E.OperationId := LastId; E.Available := True; FFake.EmitProgress(E);
  FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(Op.State));
  AssertEquals(Ord(lbaAvailable),Ord(Op.Availability));
end;

procedure TLazBleContractTest.ShutdownKeepsAvailabilityUnavailable;
var
  Backend: ILazBleBackend;
  Fake: TFakeLazBleBackend;
  Ble: TLazBle;
  AvailabilityOp, RejectedCheck: IBleAvailabilityOperation;
  Shutdown: IBleOperation;
  Event: TLazBleBackendEvent;
  Outcome: TLazBleBackendEventKind;
begin
  for Outcome in [lbekOperationSucceeded, lbekOperationFailed,
    lbekOperationCancelled] do
  begin
    Fake := TFakeLazBleBackend.Create;
    Backend := Fake;
    Ble := TLazBle.Create(Backend);
    try
      AvailabilityOp := Ble.CheckAvailabilityAsync('');
      Shutdown := Ble.ShutdownAsync;
      AssertEquals(Ord(lbaUnavailable), Ord(Ble.DiagnosticInfo.Availability));
      Event := Default(TLazBleBackendEvent);
      Event.Kind := lbekAvailabilityResult;
      Event.OperationId := Fake.OperationIds[0];
      Event.Available := True;
      AssertTrue(Fake.EmitProgress(Event));
      AssertEquals(Ord(lbaUnavailable), Ord(Ble.DiagnosticInfo.Availability));
      AssertTrue(Fake.CompleteOperation(Event.OperationId, Outcome,
        0, 'late check outcome'));
      case Outcome of
        lbekOperationSucceeded:
          begin
            AssertEquals(Ord(lbopSucceeded), Ord(AvailabilityOp.State));
            AssertEquals(Ord(lbaAvailable), Ord(AvailabilityOp.Availability));
          end;
        lbekOperationFailed:
          begin
            AssertEquals(Ord(lbopFailed), Ord(AvailabilityOp.State));
            AssertEquals('late check outcome', AvailabilityOp.ErrorMessage);
          end;
        lbekOperationCancelled:
          AssertEquals(Ord(lbopCancelled), Ord(AvailabilityOp.State));
      end;
      AssertEquals(Ord(lbaUnavailable), Ord(Ble.DiagnosticInfo.Availability));
      if Outcome = lbekOperationFailed then
        AssertEquals('late check outcome', Ble.DiagnosticInfo.AvailabilityErrorMessage)
      else
        AssertEquals('', Ble.DiagnosticInfo.AvailabilityErrorMessage);
      AssertTrue(Fake.CompleteShutdown);
      AssertEquals(Ord(lbopSucceeded), Ord(Shutdown.State));
      AssertEquals(Ord(lbaUnavailable), Ord(Ble.DiagnosticInfo.Availability));
      RejectedCheck := Ble.CheckAvailabilityAsync('');
      AssertEquals(Ord(lbopFailed), Ord(RejectedCheck.State));
      AssertEquals(LazBleErrorInvalidState, RejectedCheck.ErrorCode);
      AssertEquals(Ord(lbaUnavailable), Ord(Ble.DiagnosticInfo.Availability));
      AssertEquals(1, Fake.CommandCount);
    finally
      Ble.Free;
      Backend := nil;
    end;
  end;
end;

procedure TLazBleContractTest.ShutdownPreservesCleanupFailureZero;
var Op: IBleOperation;
begin
  Op := FBle.ShutdownAsync; Op.Cancel;
  AssertEquals(Ord(lbopPending),Ord(Op.State));
  AssertTrue(FFake.CompleteShutdown(0,'cleanup invalid argument'));
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(0,Op.ErrorCode);
  AssertEquals('cleanup invalid argument',Op.ErrorMessage);
  AssertTrue(FFake.ShutdownStarted); AssertTrue(Op=FBle.ShutdownAsync);
end;

procedure TLazBleContractTest.PendingUnsubscribeWaitsForCancelledNotify;
var Sub: IBleSubscription; Op: IBleGattOperation;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify');
  Sub.OnData := @Data; Op := Sub.Unsubscribe;
  AssertEquals(Ord(lbopPending),Ord(Op.State));
  AssertEquals(Ord(lbsubUnsubscribing),Ord(Sub.State));
  AssertTrue(FFake.CancellationWasRequested(LastId));
  Emit(lbekNotification,0,7); AssertEquals(0,FValues);
  FFake.CompleteOperation(LastId,lbekOperationCancelled);
  AssertEquals(Ord(lbopSucceeded),Ord(Op.State));
  AssertEquals(Ord(lbsubInactive),Ord(Sub.State)); AssertEquals(3,FFake.CommandCount);
end;

procedure TLazBleContractTest.PendingUnsubscribeCleansSuccessfulNotify;
var Sub: IBleSubscription; Op: IBleGattOperation; NotifyId: TBleOperationId;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify'); NotifyId := LastId;
  Sub.OnData := @Data; Op := Sub.Unsubscribe;
  Emit(lbekSubscribed,NotifyId,7); Emit(lbekNotification,0,7);
  AssertEquals(0,FValues); AssertEquals(Ord(lbopPending),Ord(Op.State));
  FFake.CompleteOperation(NotifyId,lbekOperationSucceeded);
  AssertEquals(4,FFake.CommandCount);
  AssertEquals(Ord(lbckUnsubscribe),Ord(FFake.Commands[3].Kind));
  AssertEquals(QWord(7),QWord(FFake.Commands[3].SubscriptionId));
  AssertEquals(Ord(lbopPending),Ord(Op.State));
  Op.Cancel; { retirement/cleanup is irreversible and continues }
  AssertFalse(FFake.CancellationWasRequested(LastId));
  FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(Op.State));
  AssertEquals(Ord(lbsubInactive),Ord(Sub.State)); AssertTrue(Op=Sub.Unsubscribe);
end;

procedure TLazBleContractTest.FailedUnsubscribeRetiresTokenAndDisconnects;
var Sub: IBleSubscription; Op, ReadOp: IBleGattOperation;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify');
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  Sub.OnData := @Data; Op := Sub.Unsubscribe;
  FFake.CompleteOperation(LastId,lbekOperationFailed,0,'native unsubscribe failed');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(0,Sub.ErrorCode);
  AssertEquals('native unsubscribe failed',Sub.ErrorMessage);
  AssertEquals(Ord(lbsubFailed),Ord(Sub.State)); Emit(lbekNotification,0,7);
  AssertEquals(0,FValues);
  AssertEquals(Ord(lbckDisconnect),Ord(FFake.Commands[4].Kind));
  ReadOp := FClient.ReadAsync('service','read');
  AssertEquals(Ord(lbopFailed),Ord(ReadOp.State));
  Emit(lbekDisconnected,LastId); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(Ord(lbcstDisconnected),Ord(FClient.State));
end;

procedure TLazBleContractTest.EarlyNotificationIsDropped;
var Sub: IBleSubscription;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify'); Sub.OnData := @Data;
  Emit(lbekNotification,0,7); AssertEquals(0,FValues);
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  AssertEquals(0,FValues);
  Emit(lbekNotification,0,7); AssertEquals(1,FValues);
end;

procedure TLazBleContractTest.CoreRejectsForeignThread;
var Worker: TForeignCall;
begin
  Worker := TForeignCall.Create(True); Worker.Ble := FBle; Worker.Client := FClient;
  Worker.Operation := FBle.ScanAsync('',10);
  try Worker.Start; Worker.WaitFor; AssertEquals(3,Worker.Rejected); finally Worker.Free; end;
end;

procedure TLazBleContractTest.SyncDeadlineDoesNotCancelOperation;
var Sync: TLazBleSync; Backend: ILazBleBackend; Fake: TFakeLazBleBackend;
  Client: TBleClient; Op: IBleOperation; E: TLazBleBackendEvent; Error: string;
begin
  Fake := TFakeLazBleBackend.Create; Backend := Fake; Sync := TLazBleSync.Create(Backend);
  try
    Client := Sync.CreateClient('sync'); Op := Client.ConnectAsync;
    AssertFalse(Sync.Connect(Client,5,Error));
    AssertTrue(Pos('may still be running',Error)>0);
    AssertEquals(Ord(lbopPending),Ord(Op.State)); AssertEquals(0,Fake.CancelledOperationCount);
    E := Default(TLazBleBackendEvent); E.Kind := lbekConnected; E.OperationId := Fake.OperationIds[0];
    E.DeviceId := 'sync'; Fake.EmitProgress(E);
    Fake.CompleteOperation(Fake.OperationIds[0],lbekOperationSucceeded);
    E.Kind := lbekServicesDiscovered; E.OperationId := Fake.OperationIds[1]; Fake.EmitProgress(E);
    Fake.CompleteOperation(Fake.OperationIds[1],lbekOperationSucceeded);
    AssertEquals(Ord(lbopSucceeded),Ord(Op.State));
    Sync.Shutdown(0,Error); AssertTrue(Fake.CompleteShutdown);
  finally Sync.Free; end;
end;

procedure TLazBleContractTest.PendingOperationOutlivesDestroyedOwner;
var Op: IBleOperation;
begin
  Op := FBle.ScanAsync('',10); FreeAndNil(FBle);
  Op.Cancel;
  AssertFalse('Owner teardown detaches its cancellation handler',Op.State=lbopPending);
end;

procedure TLazBleContractTest.ShutdownFailureDoesNotDependOnCodeOrText;
var Op: IBleOperation;
begin
  Op := FBle.ShutdownAsync;
  AssertTrue(FFake.CompleteShutdown(0,'',True));
  AssertEquals(Ord(lbopFailed),Ord(Op.State));
  AssertEquals(0,Op.ErrorCode); AssertEquals('',Op.ErrorMessage);
end;

procedure TLazBleContractTest.DisconnectWhenConnected(Sender: TObject);
begin FNextOperation := FClient.DisconnectAsync; end;
procedure TLazBleContractTest.RestartWhenDisconnected(Sender: TObject);
begin FNextOperation := FClient.ConnectAsync; end;
procedure TLazBleContractTest.TryReadAfterUnsubscribeFailure(Sender: TObject);
begin FNextRead := FClient.ReadAsync('service','value'); end;

procedure TLazBleContractTest.ConnectCompletionCanStartDisconnect;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Op.OnCompleted := @DisconnectWhenConnected;
  Id := LastId; Emit(lbekConnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopPending),Ord(FNextOperation.State));
  AssertEquals(Ord(lbcstDisconnecting),Ord(FClient.State));
  Id := LastId; Emit(lbekDisconnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(FNextOperation.State));
end;

procedure TLazBleContractTest.DisconnectCompletionCanStartNewConnect;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Connect; Op := FClient.DisconnectAsync; Op.OnCompleted := @RestartWhenDisconnected;
  Id := LastId; Emit(lbekDisconnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbcstConnecting),Ord(FClient.State));
  AssertEquals(Ord(lbopPending),Ord(FNextOperation.State));
  Id := LastId; Emit(lbekConnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(FNextOperation.State));
end;

procedure TLazBleContractTest.UnsubscribeFailureBlocksReentrantRead;
var Sub: IBleSubscription; Op: IBleGattOperation;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify');
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  Op := Sub.Unsubscribe; Op.OnCompleted := @TryReadAfterUnsubscribeFailure;
  FFake.CompleteOperation(LastId,lbekOperationFailed,0,'unsubscribe failed');
  AssertEquals(Ord(lbopFailed),Ord(FNextRead.State));
  AssertEquals(Ord(lbcstDisconnecting),Ord(FClient.State));
end;

procedure TLazBleContractTest.ShutdownPreservesStartedReadValue;
var ReadOp: IBleGattOperation; ShutdownOp: IBleOperation; Id: TBleOperationId;
begin
  Connect; ReadOp := FClient.ReadAsync('service','value'); Id := LastId;
  ShutdownOp := FBle.ShutdownAsync;
  Emit(lbekReadResult,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(ReadOp.State)); AssertEquals(42,ReadOp.Value[0]);
  FFake.CompleteShutdown; AssertEquals(Ord(lbopSucceeded),Ord(ShutdownOp.State));
end;

procedure TLazBleContractTest.ShutdownDoesNotActivatePendingSubscription;
var Sub: IBleSubscription; ShutdownOp: IBleOperation; Id: TBleOperationId;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify'); Id := LastId; Sub.OnData := @Data;
  ShutdownOp := FBle.ShutdownAsync;
  Emit(lbekSubscribed,Id,7); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Emit(lbekNotification,0,7);
  AssertFalse(Sub.State=lbsubActive); AssertEquals(0,FValues);
  FFake.CompleteShutdown; AssertEquals(Ord(lbopSucceeded),Ord(ShutdownOp.State));
  AssertEquals(Ord(lbsubInactive),Ord(Sub.State));
end;

procedure TLazBleContractTest.UnsubscribeRecoveryRetainsReconnectPolicy;
var Sub: IBleSubscription; Op: IBleGattOperation; Id: TBleOperationId; Deadline: QWord;
begin
  Connect; FClient.ReconnectOptions := TLazBleReconnectOptions.Create(1,2,2);
  FClient.AutoReconnect := True;
  Sub := FClient.SubscribeAsync('service','notify');
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  Op := Sub.Unsubscribe;
  FFake.CompleteOperation(LastId,lbekOperationFailed,0,'unsubscribe failed');
  Id := LastId; Emit(lbekDisconnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Deadline := GetTickCount64+2000;
  while (FFake.CommandCount<6) and (GetTickCount64<Deadline) do CheckSynchronize(5);
  AssertEquals(6,FFake.CommandCount); AssertEquals(Ord(lbckConnect),Ord(FFake.Commands[5].Kind));
end;

procedure TLazBleContractTest.DisconnectDoesNotInventGattCancellation;
var Op: IBleGattOperation; Id: TBleOperationId;
begin
  Connect; Op := FClient.ReadAsync('service','value'); Id := LastId;
  Emit(lbekDisconnected,0);
  AssertEquals(Ord(lbopPending),Ord(Op.State));
  FFake.CompleteOperation(Id,lbekOperationFailed,0,'link lost during read');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(0,Op.ErrorCode);
  AssertEquals('link lost during read',Op.ErrorMessage);
end;

procedure TLazBleContractTest.OldGenerationReadRetainsActualValue;
var ReadOp: IBleGattOperation; ConnectOp: IBleOperation;
  ReadId, ConnectId, DiscoveryId: TBleOperationId; E: TLazBleBackendEvent; OldGeneration: QWord;
begin
  Connect; ReadOp := FClient.ReadAsync('service','value'); ReadId := LastId;
  OldGeneration := FFake.Commands[2].Generation; Emit(lbekDisconnected,0);
  ConnectOp := FClient.ConnectAsync; ConnectId := LastId;
  AssertTrue(FFake.Commands[3].Generation>OldGeneration);
  E := Default(TLazBleBackendEvent); E.Kind := lbekReadResult; E.OperationId := ReadId;
  E.Generation := OldGeneration; E.DeviceId := 'peer'; E.Value := TBytes.Create(91);
  FFake.EmitProgress(E); FFake.CompleteOperation(ReadId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(ReadOp.State)); AssertEquals(91,ReadOp.Value[0]);
  AssertEquals(Ord(lbcstConnecting),Ord(FClient.State));
  Emit(lbekConnected,ConnectId); FFake.CompleteOperation(ConnectId,lbekOperationSucceeded);
  DiscoveryId := LastId; Emit(lbekServicesDiscovered,DiscoveryId);
  FFake.CompleteOperation(DiscoveryId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(ConnectOp.State));
end;

procedure TLazBleContractTest.UnsubscribeResultSurvivesDisconnectAndDroppedToken;
var Sub: IBleSubscription; Op: IBleGattOperation; Id: TBleOperationId;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify');
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  Op := Sub.Unsubscribe; Id := LastId; Emit(lbekDisconnected,0);
  AssertEquals(Ord(lbopPending),Ord(Op.State)); Sub := nil;
  FFake.CompleteOperation(Id,lbekOperationFailed,4,'native unsubscribe lost connection');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(4,Op.ErrorCode);
  AssertEquals('native unsubscribe lost connection',Op.ErrorMessage);
end;

procedure TLazBleContractTest.OldUnsubscribeFailureDoesNotDisconnectNewSession;
var Sub: IBleSubscription; Op: IBleGattOperation; ConnectOp: IBleOperation;
  UnsubscribeId, Id: TBleOperationId;
begin
  Connect; Sub := FClient.SubscribeAsync('service','notify');
  Emit(lbekSubscribed,LastId,7); FFake.CompleteOperation(LastId,lbekOperationSucceeded);
  Op := Sub.Unsubscribe; UnsubscribeId := LastId; Emit(lbekDisconnected,0);
  ConnectOp := FClient.ConnectAsync; Id := LastId;
  Emit(lbekConnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  { A custom backend may complete old work later than the new connection. }
  FFake.CompleteOperation(UnsubscribeId,lbekOperationFailed,4,'old link lost');
  AssertEquals(Ord(lbopFailed),Ord(Op.State)); AssertEquals(Ord(lbopSucceeded),Ord(ConnectOp.State));
  AssertEquals(Ord(lbcstReady),Ord(FClient.State)); AssertEquals(6,FFake.CommandCount);
end;

procedure TLazBleContractTest.DisconnectCancellationKeepsCleanup;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Connect; Op := FClient.DisconnectAsync; Id := LastId; Op.Cancel;
  AssertTrue(Op.CancelRequested); AssertFalse(FFake.CancellationWasRequested(Id));
  Emit(lbekDisconnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(Op.State));
  AssertEquals(Ord(lbcstDisconnected),Ord(FClient.State));
end;

procedure TLazBleContractTest.DisconnectCancellationDoesNotRestorePartialConnect;
var ConnectOp, DisconnectOp: IBleOperation; ConnectId, DisconnectId: TBleOperationId;
begin
  ConnectOp := FClient.ConnectAsync; ConnectId := LastId;
  DisconnectOp := FClient.DisconnectAsync; DisconnectId := LastId; DisconnectOp.Cancel;
  Emit(lbekConnected,ConnectId); FFake.CompleteOperation(ConnectId,lbekOperationSucceeded);
  AssertEquals('No new discovery during explicit disconnect',2,FFake.CommandCount);
  Emit(lbekDisconnected,DisconnectId); FFake.CompleteOperation(DisconnectId,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(DisconnectOp.State));
  AssertEquals(Ord(lbopFailed),Ord(ConnectOp.State));
end;

procedure TLazBleContractTest.QueuedCancelCompletionCanStartNextConnect;
var Op: IBleOperation; Id: TBleOperationId;
begin
  Op := FClient.ConnectAsync; Id := LastId; Op.OnCompleted := @RestartWhenDisconnected;
  Op.Cancel; FFake.CompleteOperation(Id,lbekOperationCancelled);
  AssertEquals(Ord(lbcstConnecting),Ord(FClient.State));
  AssertEquals(Ord(lbopPending),Ord(FNextOperation.State));
  Id := LastId; Emit(lbekConnected,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  Id := LastId; Emit(lbekServicesDiscovered,Id); FFake.CompleteOperation(Id,lbekOperationSucceeded);
  AssertEquals(Ord(lbopSucceeded),Ord(FNextOperation.State));
end;

initialization
  RegisterTest(TLazBleContractTest);
end.
