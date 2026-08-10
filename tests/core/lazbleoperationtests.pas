unit LazBleOperationTests;

{$mode objfpc}{$H+}

interface

uses
  fpcunit,
  testregistry,
  LazBleOperation;

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
  end;

  TLazBleOperationTest = class(TTestCase)
  published
    procedure LateCompletionHandlerRunsExactlyOnce;
    procedure InterfaceOwnsCompletedOperationLifetime;
    procedure CancelWithoutBackendCompletesOperation;
  end;

implementation

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

procedure TLazBleOperationTest.CancelWithoutBackendCompletesOperation;
var
  Operation: IBleOperation;
begin
  Operation := TTrackedOperation.CreateTracked(nil);

  Operation.Cancel;

  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertTrue(Operation.CancelRequested);
end;

initialization
  RegisterTest(TLazBleOperationTest);

end.
