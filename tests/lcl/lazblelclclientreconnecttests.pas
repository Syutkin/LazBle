unit LazBleLclClientReconnectTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  FpcUnit,
  TestRegistry,
  LazBleTypes,
  LazBleBackend,
  LazBleClient,
  LazBleGattProfile,
  LazBleComponent,
  FakeLazBleBackend;

type
  TPassiveGattProfile = class(TBleGattProfile)
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  end;

  TLazBleLclClientReconnectTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FLazBle: TLazBleComponent;
    FClient: TLazBleLclClient;
    procedure AssertCoreOptions(const AInitialDelayMs, AMaximumDelayMs,
      AMaximumAttempts: Cardinal);
    procedure EnterWaitingReconnect;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsDoNotCreateCoreClient;
    procedure SettingsRejectInvalidValuesWithoutChangingCurrentValue;
    procedure SettingsAndAutoReconnectApplyToLazyCoreClient;
    procedure SettingsChangesApplyToExistingCoreClient;
    procedure ReplacementCoreReceivesTheSameSettings;
    procedure AttemptAndDelayReflectCoreReconnectState;
    procedure WaitingReconnectRequiresDisconnectBeforeDeviceChange;
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

procedure TPassiveGattProfile.DoAttach;
begin
  MarkReady;
end;

procedure TPassiveGattProfile.DoDetach;
begin
end;

procedure TLazBleLclClientReconnectTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FLazBle := TLazBleComponent.Create(nil, FBackend);
  FClient := TLazBleLclClient.Create(nil);
  FClient.LazBle := FLazBle;
  FClient.DeviceId := 'device-a';
end;

procedure TLazBleLclClientReconnectTest.TearDown;
begin
  FClient.Free;
  FClient := nil;
  FLazBle.Free;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleLclClientReconnectTest.AssertCoreOptions(
  const AInitialDelayMs, AMaximumDelayMs, AMaximumAttempts: Cardinal);
var
  Options: TLazBleReconnectOptions;
begin
  Options := FClient.CoreClient.ReconnectOptions;
  AssertEquals(Int64(AInitialDelayMs), Int64(Options.InitialDelayMs));
  AssertEquals(Int64(AMaximumDelayMs), Int64(Options.MaximumDelayMs));
  AssertEquals(Int64(AMaximumAttempts), Int64(Options.MaximumAttempts));
end;

procedure TLazBleLclClientReconnectTest.EnterWaitingReconnect;
var
  BackendEvent: TLazBleBackendEvent;
  Generation: QWord;
  OperationId: TBleOperationId;
begin
  FClient.ReconnectOptions.MaximumDelayMs := 60000;
  FClient.ReconnectOptions.InitialDelayMs := 60000;
  FClient.ReconnectOptions.MaximumAttempts := 2;
  FClient.AutoReconnect := True;
  FClient.AddProfile(TPassiveGattProfile.Create);
  FClient.Connect;
  Generation := TBleClientGenerationAccess(
    FClient.CoreClient).ExposedGeneration;

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekConnected;
  BackendEvent.OperationId := OperationId;
  BackendEvent.DeviceId := FClient.DeviceId;
  BackendEvent.Generation := Generation;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := OperationId;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  AssertEquals(Ord(lbcstReady), Ord(FClient.State));

  BackendEvent.Kind := lbekDisconnected;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  AssertEquals(Ord(lbcstWaitingToReconnect), Ord(FClient.State));
end;

procedure TLazBleLclClientReconnectTest.DefaultsDoNotCreateCoreClient;
begin
  AssertFalse(FClient.AutoReconnect);
  AssertEquals(1000, Integer(FClient.ReconnectOptions.InitialDelayMs));
  AssertEquals(30000, Integer(FClient.ReconnectOptions.MaximumDelayMs));
  AssertEquals(5, Integer(FClient.ReconnectOptions.MaximumAttempts));
  AssertEquals(0, Integer(FClient.ReconnectAttempt));
  AssertEquals(0, Integer(FClient.ReconnectDelayMs));
  AssertNull(FClient.CoreClient);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleLclClientReconnectTest.SettingsRejectInvalidValuesWithoutChangingCurrentValue;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    FClient.ReconnectOptions.InitialDelayMs := 0;
  except
    on EArgumentOutOfRangeException do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals(1000, Integer(FClient.ReconnectOptions.InitialDelayMs));

  Raised := False;
  try
    FClient.ReconnectOptions.MaximumDelayMs := 500;
  except
    on EArgumentOutOfRangeException do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals(30000, Integer(FClient.ReconnectOptions.MaximumDelayMs));

  Raised := False;
  try
    FClient.ReconnectOptions.MaximumAttempts := 0;
  except
    on EArgumentOutOfRangeException do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals(5, Integer(FClient.ReconnectOptions.MaximumAttempts));
  AssertNull(FClient.CoreClient);
end;

procedure TLazBleLclClientReconnectTest.SettingsAndAutoReconnectApplyToLazyCoreClient;
begin
  FClient.ReconnectOptions.InitialDelayMs := 250;
  FClient.ReconnectOptions.MaximumDelayMs := 4000;
  FClient.ReconnectOptions.MaximumAttempts := 7;
  FClient.AutoReconnect := True;

  FClient.AddProfile(TPassiveGattProfile.Create);

  AssertNotNull(FClient.CoreClient);
  AssertTrue(FClient.CoreClient.AutoReconnect);
  AssertCoreOptions(250, 4000, 7);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleLclClientReconnectTest.SettingsChangesApplyToExistingCoreClient;
begin
  FClient.AddProfile(TPassiveGattProfile.Create);

  FClient.AutoReconnect := True;
  FClient.ReconnectOptions.InitialDelayMs := 500;
  FClient.ReconnectOptions.MaximumDelayMs := 8000;
  FClient.ReconnectOptions.MaximumAttempts := 9;

  AssertTrue(FClient.CoreClient.AutoReconnect);
  AssertCoreOptions(500, 8000, 9);

  FClient.AutoReconnect := False;
  AssertFalse(FClient.CoreClient.AutoReconnect);
end;

procedure TLazBleLclClientReconnectTest.ReplacementCoreReceivesTheSameSettings;
var
  DeviceInfo: TBleDeviceInfo;
begin
  FClient.ReconnectOptions.InitialDelayMs := 750;
  FClient.ReconnectOptions.MaximumDelayMs := 9000;
  FClient.ReconnectOptions.MaximumAttempts := 4;
  FClient.AutoReconnect := True;
  FClient.AddProfile(TPassiveGattProfile.Create);

  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := 'device-b';
  DeviceInfo.DeviceName := 'Replacement';
  FClient.SelectDevice(DeviceInfo);
  AssertNull(FClient.CoreClient);

  FClient.AddProfile(TPassiveGattProfile.Create);

  AssertEquals('device-b', FClient.CoreClient.DeviceId);
  AssertTrue(FClient.CoreClient.AutoReconnect);
  AssertCoreOptions(750, 9000, 4);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleLclClientReconnectTest.AttemptAndDelayReflectCoreReconnectState;
begin
  EnterWaitingReconnect;
  AssertEquals(1, Integer(FClient.ReconnectAttempt));
  AssertEquals(60000, Integer(FClient.ReconnectDelayMs));

  FClient.Disconnect;
  CheckSynchronize;
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
  AssertEquals(0, Integer(FClient.ReconnectAttempt));
  AssertEquals(0, Integer(FClient.ReconnectDelayMs));
end;

procedure TLazBleLclClientReconnectTest.WaitingReconnectRequiresDisconnectBeforeDeviceChange;
var
  DeviceInfo: TBleDeviceInfo;
  Raised: Boolean;
begin
  EnterWaitingReconnect;
  DeviceInfo := Default(TBleDeviceInfo);
  DeviceInfo.DeviceId := 'device-b';
  DeviceInfo.DeviceName := 'Replacement';

  Raised := False;
  try
    FClient.SelectDevice(DeviceInfo);
  except
    on EInvalidOperation do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals('device-a', FClient.DeviceId);
  AssertNotNull(FClient.CoreClient);

  FClient.Disconnect;
  CheckSynchronize;
  AssertEquals(Ord(lbcstDisconnected), Ord(FClient.State));
  FClient.SelectDevice(DeviceInfo);

  AssertEquals('device-b', FClient.DeviceId);
  AssertNull(FClient.CoreClient);
  AssertEquals(0, Integer(FClient.ReconnectAttempt));
  AssertEquals(0, Integer(FClient.ReconnectDelayMs));
end;

initialization
  RegisterTest(TLazBleLclClientReconnectTest);

end.
