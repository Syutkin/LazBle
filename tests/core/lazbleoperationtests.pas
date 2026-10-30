unit LazBleOperationTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleOperation, LazBleBackend, LazBleGattOperation;

type
  TOperationObserver = class
  private
    FCompletionCount: Integer;
  public
    procedure Completed(Sender: TObject);
    property CompletionCount: Integer read FCompletionCount;
  end;

  TTrackedOperation = class(TBleOperation)
  private
    FDestroyCounter: PInteger;
  public
    constructor CreateTracked(const ADestroyCount: PInteger);
    destructor Destroy; override;
    procedure Succeed;
    procedure FailNative;
  end;

  TLazBleOperationTest = class(TTestCase)
  private
    FObserved: Integer;
    procedure ObserveRead(Sender: TObject);
  published
    procedure LateCompletionHandlerRunsExactlyOnce;
    procedure InterfaceOwnsCompletedOperationLifetime;
    procedure CancelWithoutHandlerWaitsForOutcome;
    procedure CancelDoesNotHideNativeFailure;
    procedure AddressedReadPublishesOneCompleteResult;
    procedure AddressedFailureDoesNotDependOnCodeOrText;
    procedure AddressedCancelIsExplicit;
    procedure AddressedEmptyReadIsSuccessful;
  end;

implementation

type
  TPendingRead = class(TBleGattOperation)
    constructor Create;
  end;

constructor TPendingRead.Create;
begin
  inherited CreatePending(lbckRead);
end;

procedure TLazBleOperationTest.ObserveRead(Sender: TObject);
var Op: IBleGattOperation;
begin
  AssertTrue(Supports(Sender, IBleGattOperation, Op));
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(42, Op.Value[0]);
  Inc(FObserved);
end;

procedure TLazBleOperationTest.AddressedReadPublishesOneCompleteResult;
var Op: IBleGattOperation; Target: ILazBleRequestCompletion;
  ResultData: TLazBleRequestResult;
begin
  Op := TPendingRead.Create;
  AssertTrue(Supports(Op, ILazBleRequestCompletion, Target));
  Op.OnCompleted := @ObserveRead;
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsSucceeded;
  ResultData.Value := TBytes.Create(42);
  Target.CompleteRequest(ResultData);
  ResultData.Value := TBytes.Create(99);
  Target.CompleteRequest(ResultData);
  AssertEquals(1, FObserved);
  AssertEquals(42, Op.Value[0]);
end;

procedure TLazBleOperationTest.AddressedFailureDoesNotDependOnCodeOrText;
var Op: IBleGattOperation; Target: ILazBleRequestCompletion;
  ResultData: TLazBleRequestResult;
begin
  Op := TPendingRead.Create;
  AssertTrue(Supports(Op, ILazBleRequestCompletion, Target));
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsFailed;
  Target.CompleteRequest(ResultData);
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals(0, Op.ErrorCode);
  AssertEquals('', Op.ErrorMessage);
end;

procedure TLazBleOperationTest.AddressedCancelIsExplicit;
var Op: IBleGattOperation; Target: ILazBleRequestCompletion;
  ResultData: TLazBleRequestResult;
begin
  Op := TPendingRead.Create;
  AssertTrue(Supports(Op, ILazBleRequestCompletion, Target));
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsCancelled;
  Target.CompleteRequest(ResultData);
  AssertEquals(Ord(lbopCancelled), Ord(Op.State));
end;

procedure TLazBleOperationTest.AddressedEmptyReadIsSuccessful;
var Op: IBleGattOperation; Target: ILazBleRequestCompletion;
  ResultData: TLazBleRequestResult;
begin
  Op := TPendingRead.Create;
  AssertTrue(Supports(Op, ILazBleRequestCompletion, Target));
  ResultData := Default(TLazBleRequestResult);
  ResultData.Status := lbrsSucceeded;
  Target.CompleteRequest(ResultData);
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(0, Length(Op.Value));
end;

procedure TOperationObserver.Completed(Sender: TObject);
begin
  Inc(FCompletionCount);
end;

constructor TTrackedOperation.CreateTracked(const ADestroyCount: PInteger);
begin
  inherited Create(nil);
  FDestroyCounter := ADestroyCount;
end;

destructor TTrackedOperation.Destroy;
begin
  if Assigned(FDestroyCounter) then
    Inc(FDestroyCounter^);
  inherited Destroy;
end;

procedure TTrackedOperation.Succeed;
begin
  Complete(lbopSucceeded);
end;

procedure TTrackedOperation.FailNative;
begin Complete(lbopFailed, 0, 'native invalid argument'); end;

procedure TLazBleOperationTest.LateCompletionHandlerRunsExactlyOnce;
var
  Observer: TOperationObserver;
  Operation: IBleOperation;
  OperationObject: TTrackedOperation;
begin
  Observer := TOperationObserver.Create;
  try
    OperationObject := TTrackedOperation.CreateTracked(nil);
    Operation := OperationObject;
    OperationObject.Succeed;

    Operation.OnCompleted := @Observer.Completed;
    Operation.OnCompleted := @Observer.Completed;

    AssertEquals(1, Observer.CompletionCount);
    AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  finally
    Operation := nil;
    Observer.Free;
  end;
end;

procedure TLazBleOperationTest.InterfaceOwnsCompletedOperationLifetime;
var
  DestroyCount: Integer;
  Operation: IBleOperation;
  OperationObject: TTrackedOperation;
begin
  DestroyCount := 0;
  OperationObject := TTrackedOperation.CreateTracked(@DestroyCount);
  Operation := OperationObject;
  OperationObject.Succeed;

  AssertEquals(0, DestroyCount);
  Operation := nil;
  AssertEquals(1, DestroyCount);
end;

procedure TLazBleOperationTest.CancelWithoutHandlerWaitsForOutcome;
var Operation: IBleOperation; Instance: TTrackedOperation;
begin
  Instance := TTrackedOperation.CreateTracked(nil); Operation := Instance;
  Operation.Cancel;
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(Operation.CancelRequested);
  Instance.Succeed;
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleOperationTest.CancelDoesNotHideNativeFailure;
var Operation: IBleOperation; Instance: TTrackedOperation;
begin
  Instance := TTrackedOperation.CreateTracked(nil); Operation := Instance;
  Operation.Cancel; Instance.FailNative;
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(0, Operation.ErrorCode);
  AssertEquals('native invalid argument', Operation.ErrorMessage);
end;

initialization
  RegisterTest(TLazBleOperationTest);

end.
