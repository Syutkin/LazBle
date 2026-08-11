unit LazBleLclClientConnectionTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  FpcUnit,
  TestRegistry,
  Forms,
  LazBleTypes,
  LazBleBackend,
  LazBleClient,
  LazBleGattProfile,
  LazBleComponent,
  FakeLazBleBackend;

type
  TClientBackendAction = (
    cbtaConnectSuccess,
    cbtaConnectFailure,
    cbtaDisconnectSuccess
  );

  TClientBackendThread = class(TThread)
  private
    FBackend: TFakeLazBleBackend;
    FAction: TClientBackendAction;
    FCommandIndex: Integer;
    FDeviceId: string;
    FGeneration: QWord;
    FFinished: TEvent;
    procedure Emit(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId);
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: TFakeLazBleBackend;
      const AAction: TClientBackendAction; const ACommandIndex: Integer;
      const ADeviceId: string; const AGeneration: QWord);
    destructor Destroy; override;
    function WaitUntilFinished(const ATimeoutMs: Cardinal): TWaitResult;
  end;

  TImmediateGattProfile = class(TBleGattProfile)
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  end;

  TLazBleLclClientConnectionTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FOwnerForm: TForm;
    FLazBle: TLazBleComponent;
    FClient: TLazBleLclClient;
    FConfigureCount: Integer;
    FConnectedCount: Integer;
    FDisconnectedCount: Integer;
    FErrorCount: Integer;
    FErrorCode: Integer;
    FErrorMessage: string;
    FStates: array of TLazBleClientState;
    FLastCallbackThreadId: TThreadID;
    procedure ConfigureClient(Sender: TObject);
    procedure ClientStateChanged(Sender: TObject;
      const AState: TLazBleClientState);
    procedure ClientConnected(Sender: TObject);
    procedure ClientDisconnected(Sender: TObject);
    procedure ClientError(Sender: TObject; const AErrorCode: Integer;
      const AErrorMessage: string);
    function CoreGeneration: QWord;
    function StartBackendAction(
      const AAction: TClientBackendAction): TClientBackendThread;
    procedure WaitForAction(const AThread: TClientBackendThread);
    procedure CompleteConnect;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ConnectLazilyCreatesCoreAndDeliversMainThreadEvents;
    procedure ConnectFailureDeliversTerminalError;
    procedure DisconnectAllowsDeviceReplacementAndReconfiguration;
    procedure ErrorStateAllowsDeviceReplacementAndReconfiguration;
    procedure ActiveConnectionRejectsDeviceChange;
    procedure FormCloseDropsQueuedConnectionCallbacks;
  end;

implementation

type
  TBleClientGenerationAccess = class(TBleClient)
  public
    function ExposedGeneration: QWord;
  end;

function TBleClientGenerationAccess.ExposedGeneration: QWord;
begin
  Result := Generation;
end;

constructor TClientBackendThread.Create(
  const ABackend: TFakeLazBleBackend; const AAction: TClientBackendAction;
  const ACommandIndex: Integer; const ADeviceId: string;
  const AGeneration: QWord);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := ABackend;
  FAction := AAction;
  FCommandIndex := ACommandIndex;
  FDeviceId := ADeviceId;
  FGeneration := AGeneration;
  FFinished := TEvent.Create(nil, True, False, '');
end;

destructor TClientBackendThread.Destroy;
begin
  FFinished.Free;
  inherited Destroy;
end;

procedure TClientBackendThread.Emit(const AKind: TLazBleBackendEventKind;
  const AOperationId: TBleOperationId);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AKind;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := FDeviceId;
  BackendEvent.Generation := FGeneration;
  FBackend.EmitProgress(BackendEvent);
end;

procedure TClientBackendThread.Execute;
var
  OperationId: TBleOperationId;
begin
  try
    OperationId := FBackend.OperationIds[FCommandIndex];
    case FAction of
      cbtaConnectSuccess:
        begin
          Emit(lbekConnected, OperationId);
          OperationId := FBackend.OperationIds[FBackend.CommandCount - 1];
          Emit(lbekServicesDiscovered, OperationId);
        end;
      cbtaConnectFailure:
        FBackend.CompleteOperation(OperationId, lbekOperationFailed, 55,
          'Connection rejected');
      cbtaDisconnectSuccess:
        Emit(lbekDisconnected, OperationId);
    end;
  finally
    FFinished.SetEvent;
  end;
end;

function TClientBackendThread.WaitUntilFinished(
  const ATimeoutMs: Cardinal): TWaitResult;
begin
  Result := FFinished.WaitFor(ATimeoutMs);
end;

procedure TImmediateGattProfile.DoAttach;
begin
  MarkReady;
end;

procedure TImmediateGattProfile.DoDetach;
begin
end;

procedure TLazBleLclClientConnectionTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FOwnerForm := TForm.CreateNew(nil);
  FLazBle := TLazBleComponent.Create(FOwnerForm, FBackend);
  FClient := TLazBleLclClient.Create(FOwnerForm);
  FClient.LazBle := FLazBle;
  FClient.DeviceId := 'device-a';
  FClient.OnConfigureClient := @ConfigureClient;
  FClient.OnStateChanged := @ClientStateChanged;
  FClient.OnConnected := @ClientConnected;
  FClient.OnDisconnected := @ClientDisconnected;
  FClient.OnError := @ClientError;
end;

procedure TLazBleLclClientConnectionTest.TearDown;
begin
  FOwnerForm.Free;
  FOwnerForm := nil;
  FClient := nil;
  CheckSynchronize;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleLclClientConnectionTest.ConfigureClient(Sender: TObject);
begin
  Inc(FConfigureCount);
  AssertSame(FClient, Sender);
  AssertNotNull(FClient.CoreClient);
  FClient.AddProfile(TImmediateGattProfile.Create, True);
end;

procedure TLazBleLclClientConnectionTest.ClientStateChanged(Sender: TObject;
  const AState: TLazBleClientState);
var
  Index: Integer;
begin
  Index := Length(FStates);
  SetLength(FStates, Index + 1);
  FStates[Index] := AState;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclClientConnectionTest.ClientConnected(Sender: TObject);
begin
  Inc(FConnectedCount);
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclClientConnectionTest.ClientDisconnected(Sender: TObject);
begin
  Inc(FDisconnectedCount);
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclClientConnectionTest.ClientError(Sender: TObject;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Inc(FErrorCount);
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

function TLazBleLclClientConnectionTest.CoreGeneration: QWord;
begin
  Result := TBleClientGenerationAccess(FClient.CoreClient).ExposedGeneration;
end;

function TLazBleLclClientConnectionTest.StartBackendAction(
  const AAction: TClientBackendAction): TClientBackendThread;
begin
  Result := TClientBackendThread.Create(FBackendObject, AAction,
    FBackendObject.CommandCount - 1, FClient.DeviceId, CoreGeneration);
  Result.Start;
end;

procedure TLazBleLclClientConnectionTest.WaitForAction(
  const AThread: TClientBackendThread);
begin
  AssertEquals('Backend action did not finish', Ord(wrSignaled),
    Ord(AThread.WaitUntilFinished(5000)));
end;

procedure TLazBleLclClientConnectionTest.CompleteConnect;
var
  Thread: TClientBackendThread;
begin
  Thread := StartBackendAction(cbtaConnectSuccess);
  try
    WaitForAction(Thread);
    CheckSynchronize;
  finally
    Thread.Free;
  end;
end;

procedure TLazBleLclClientConnectionTest.ConnectLazilyCreatesCoreAndDeliversMainThreadEvents;
begin
  AssertNull(FClient.CoreClient);
  AssertEquals(0, FBackendObject.CommandCount);

  FClient.Connect;

  AssertNotNull(FClient.CoreClient);
  AssertEquals(1, FConfigureCount);
  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckConnect), Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('device-a', FBackendObject.Commands[0].DeviceId);
  CompleteConnect;

  AssertEquals(Ord(lbcstReady), Ord(FClient.State));
  AssertEquals(1, FConnectedCount);
  AssertEquals(0, FErrorCount);
  AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
  AssertTrue(Length(FStates) >= 3);
  AssertEquals(Ord(lbcstConnecting), Ord(FStates[0]));
  AssertEquals(Ord(lbcstReady), Ord(FStates[High(FStates)]));
end;

procedure TLazBleLclClientConnectionTest.ConnectFailureDeliversTerminalError;
var
  Thread: TClientBackendThread;
begin
  FClient.Connect;
  Thread := StartBackendAction(cbtaConnectFailure);
  try
    WaitForAction(Thread);
    CheckSynchronize;
  finally
    Thread.Free;
  end;

  AssertEquals(Ord(lbcstError), Ord(FClient.State));
  AssertEquals(0, FConnectedCount);
  AssertEquals(1, FErrorCount);
  AssertEquals(0, FErrorCode);
  AssertEquals('Could not connect and discover GATT services',
    FErrorMessage);
  AssertEquals(0, FClient.LastErrorCode);
  AssertEquals('Could not connect and discover GATT services',
    FClient.LastErrorMessage);
  AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
end;

procedure TLazBleLclClientConnectionTest.DisconnectAllowsDeviceReplacementAndReconfiguration;
var
  ConnectedHandler: TNotifyEvent;
  DeviceInfo: TBleDeviceInfo;
  Thread: TClientBackendThread;
begin
  FClient.Connect;
  CompleteConnect;
  ConnectedHandler := FClient.OnConnected;

  FClient.Disconnect;
  Thread := StartBackendAction(cbtaDisconnectSuccess);
  try
    WaitForAction(Thread);
    CheckSynchronize;
  finally
    Thread.Free;
  end;

  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
  AssertEquals(1, FDisconnectedCount);
  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := 'device-b';
  DeviceInfo.DeviceName := 'Replacement';
  DeviceInfo.Rssi := -40;
  FClient.SelectDevice(DeviceInfo);
  AssertNull(FClient.CoreClient);
  AssertNull(FLazBle.Facade.FindClient('device-a'));
  AssertTrue(TMethod(FClient.OnConnected).Code =
    TMethod(ConnectedHandler).Code);
  AssertTrue(TMethod(FClient.OnConnected).Data =
    TMethod(ConnectedHandler).Data);

  FClient.Connect;
  AssertEquals(2, FConfigureCount);
  AssertEquals('device-b', FClient.CoreClient.DeviceId);
  AssertEquals('device-b', FBackendObject.Commands[
    FBackendObject.CommandCount - 1].DeviceId);
end;

procedure TLazBleLclClientConnectionTest.ActiveConnectionRejectsDeviceChange;
var
  DeviceInfo: TBleDeviceInfo;
  Raised: Boolean;
begin
  FClient.Connect;
  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := 'device-b';
  DeviceInfo.DeviceName := 'Other';
  Raised := False;
  try
    FClient.SelectDevice(DeviceInfo);
  except
    on EInvalidOperation do
      Raised := True;
  end;

  AssertTrue(Raised);
  AssertEquals('device-a', FClient.DeviceId);
  AssertEquals('device-a', FClient.CoreClient.DeviceId);
end;

procedure TLazBleLclClientConnectionTest.ErrorStateAllowsDeviceReplacementAndReconfiguration;
var
  ConnectedHandler: TNotifyEvent;
  DeviceInfo: TBleDeviceInfo;
  Thread: TClientBackendThread;
begin
  FClient.Connect;
  Thread := StartBackendAction(cbtaConnectFailure);
  try
    WaitForAction(Thread);
    CheckSynchronize;
  finally
    Thread.Free;
  end;
  AssertEquals(Ord(lbcstError), Ord(FClient.State));
  ConnectedHandler := FClient.OnConnected;

  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := 'device-b';
  DeviceInfo.DeviceName := 'Replacement';
  FClient.SelectDevice(DeviceInfo);

  AssertEquals('device-b', FClient.DeviceId);
  AssertEquals('Replacement', FClient.DeviceName);
  AssertNull(FClient.CoreClient);
  AssertNull(FLazBle.Facade.FindClient('device-a'));
  AssertTrue(TMethod(FClient.OnConnected).Code =
    TMethod(ConnectedHandler).Code);
  AssertTrue(TMethod(FClient.OnConnected).Data =
    TMethod(ConnectedHandler).Data);

  FClient.Connect;
  AssertEquals(2, FConfigureCount);
  AssertEquals('device-b', FClient.CoreClient.DeviceId);
end;

procedure TLazBleLclClientConnectionTest.
  FormCloseDropsQueuedConnectionCallbacks;
var
  Thread: TClientBackendThread;
begin
  FClient.Connect;
  Thread := StartBackendAction(cbtaConnectSuccess);
  try
    WaitForAction(Thread);
    FOwnerForm.Free;
    FOwnerForm := nil;
    FClient := nil;
    FLazBle := nil;

    CheckSynchronize;

    AssertEquals(0, FConnectedCount);
  finally
    Thread.Free;
  end;
end;

initialization
  RegisterTest(TLazBleLclClientConnectionTest);

end.
