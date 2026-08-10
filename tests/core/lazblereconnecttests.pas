unit LazBleReconnectTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleReconnect,
  FakeLazBleReconnectTimer;

type
  TLazBleReconnectControllerTest = class(TTestCase)
  private
    FTimer: ILazBleReconnectTimer;
    FTimerObject: TFakeLazBleReconnectTimer;
    FController: TLazBleReconnectController;
    FElapsedCount: Integer;
    procedure Elapsed;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DisabledByDefault;
    procedure AppliesExponentialCappedBackoff;
    procedure StopsAfterMaximumAttempts;
    procedure ResetCancelsTimerAndRestartsBackoff;
    procedure DisableCancelsPendingTimer;
    procedure RejectsInvalidOptions;
    procedure DefaultTimerIsCancelledWithController;
  end;

implementation

procedure TLazBleReconnectControllerTest.Elapsed;
begin
  Inc(FElapsedCount);
end;

procedure TLazBleReconnectControllerTest.SetUp;
begin
  FTimerObject := TFakeLazBleReconnectTimer.Create;
  FTimer := FTimerObject;
  FController := TLazBleReconnectController.Create(FTimer);
  FController.OnElapsed := @Elapsed;
end;

procedure TLazBleReconnectControllerTest.TearDown;
begin
  FController.Free;
  FController := nil;
  FTimer := nil;
  FTimerObject := nil;
end;

procedure TLazBleReconnectControllerTest.DisabledByDefault;
begin
  AssertFalse(FController.Enabled);
  AssertFalse(FController.Schedule);
  AssertFalse(FTimerObject.Active);
end;

procedure TLazBleReconnectControllerTest.AppliesExponentialCappedBackoff;
begin
  FController.SetOptions(TLazBleReconnectOptions.Create(100, 250, 4));
  FController.Enable;

  AssertTrue(FController.Schedule);
  AssertEquals(1, FController.Attempt);
  AssertEquals(100, FController.DelayMs);
  AssertTrue(FTimerObject.Trigger);
  AssertEquals(1, FElapsedCount);

  AssertTrue(FController.Schedule);
  AssertEquals(2, FController.Attempt);
  AssertEquals(200, FController.DelayMs);
  AssertTrue(FTimerObject.Trigger);

  AssertTrue(FController.Schedule);
  AssertEquals(3, FController.Attempt);
  AssertEquals(250, FController.DelayMs);
end;

procedure TLazBleReconnectControllerTest.StopsAfterMaximumAttempts;
begin
  FController.SetOptions(TLazBleReconnectOptions.Create(10, 20, 2));
  FController.Enable;
  AssertTrue(FController.Schedule);
  AssertTrue(FTimerObject.Trigger);
  AssertTrue(FController.Schedule);
  AssertTrue(FTimerObject.Trigger);

  AssertFalse(FController.Schedule);
  AssertEquals(2, FController.Attempt);
  AssertFalse(FTimerObject.Active);
end;

procedure TLazBleReconnectControllerTest.ResetCancelsTimerAndRestartsBackoff;
begin
  FController.SetOptions(TLazBleReconnectOptions.Create(100, 400, 3));
  FController.Enable;
  AssertTrue(FController.Schedule);
  FController.Reset;

  AssertFalse(FTimerObject.Active);
  AssertEquals(0, FController.Attempt);
  AssertEquals(0, FController.DelayMs);
  AssertTrue(FController.Schedule);
  AssertEquals(100, FController.DelayMs);
end;

procedure TLazBleReconnectControllerTest.DisableCancelsPendingTimer;
begin
  FController.Enable;
  AssertTrue(FController.Schedule);
  FController.Disable;

  AssertFalse(FController.Enabled);
  AssertFalse(FTimerObject.Active);
  AssertFalse(FTimerObject.Trigger);
  AssertEquals(0, FElapsedCount);
end;

procedure TLazBleReconnectControllerTest.RejectsInvalidOptions;
begin
  try
    FController.SetOptions(TLazBleReconnectOptions.Create(0, 100, 1));
    Fail('Zero initial delay must be rejected');
  except
    on E: EArgumentOutOfRangeException do
      ;
  end;
  try
    FController.SetOptions(TLazBleReconnectOptions.Create(100, 50, 1));
    Fail('Maximum delay below initial delay must be rejected');
  except
    on E: EArgumentOutOfRangeException do
      ;
  end;
  try
    FController.SetOptions(TLazBleReconnectOptions.Create(100, 100, 0));
    Fail('Zero maximum attempts must be rejected');
  except
    on E: EArgumentOutOfRangeException do
      ;
  end;
end;

procedure TLazBleReconnectControllerTest.DefaultTimerIsCancelledWithController;
var
  Controller: TLazBleReconnectController;
  Factory: ILazBleReconnectTimerFactory;
  Timer: ILazBleReconnectTimer;
begin
  Factory := LazBleCreateDefaultReconnectTimerFactory;
  Timer := Factory.CreateTimer;
  Controller := TLazBleReconnectController.Create(Timer);
  Controller.OnElapsed := @Elapsed;
  Controller.SetOptions(
    TLazBleReconnectOptions.Create(60000, 60000, 1));
  Controller.Enable;
  AssertTrue(Controller.Schedule);

  Controller.Free;

  AssertEquals(0, FElapsedCount);
end;

initialization
  RegisterTest(TLazBleReconnectControllerTest);

end.
