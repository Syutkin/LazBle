unit LazBleGattOperation;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation;

type
  { Main-thread operation. Value is a read-only managed snapshot of a GATT read. }
  IBleGattOperation = interface(IBleOperation)
    ['{88355E9C-04D6-46E7-9B3E-6E3470C9E980}']
    function GetValue: TBytes;
    property Value: TBytes read GetValue;
  end;

  TBleGattOperation = class(TBleOperation, IBleGattOperation,
    ILazBleRequestCompletion)
  private
    FOperationId: TBleOperationId;
    FGeneration: QWord;
    FKind: TLazBleBackendCommandKind;
    FValue: TBytes;
    function GetValue: TBytes;
  protected
    { A local operation that awaits a chained native cleanup. }
    constructor CreatePending(const AKind: TLazBleBackendCommandKind);
    constructor Create(const AOperationId: TBleOperationId;
      const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord = 0);
    constructor CreateCompleted(const AKind: TLazBleBackendCommandKind;
      const AState: TLazBleOperationState;
      const AErrorMessage: string = '');
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure CompleteRequest(const AResult: TLazBleRequestResult);
    procedure CancelLocally;
    procedure DetachOwner;
    function MatchesOperationId(const AOperationId: TBleOperationId): Boolean;
    function GetOperationId: TBleOperationId;
    function GetKind: TLazBleBackendCommandKind;
    property OperationGeneration: QWord read FGeneration;
  public
    destructor Destroy; override;
    property Value: TBytes read GetValue;
  end;

implementation

procedure TBleGattOperation.CompleteRequest(const AResult: TLazBleRequestResult);
begin
  LazBleRequireMainThread;
  if State <> lbopPending then Exit;
  FValue := AResult.Value;
  case AResult.Status of
    lbrsSucceeded: Complete(lbopSucceeded);
    lbrsFailed: Complete(lbopFailed, AResult.ErrorCode, AResult.ErrorMessage);
    lbrsCancelled: Complete(lbopCancelled, AResult.ErrorCode, AResult.ErrorMessage);
  end;
end;

constructor TBleGattOperation.CreatePending(const AKind: TLazBleBackendCommandKind);
begin
  inherited Create(nil);
  FKind := AKind;
end;

constructor TBleGattOperation.Create(const AOperationId: TBleOperationId;
  const AKind: TLazBleBackendCommandKind;
  const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord);
begin
  inherited Create(AOnCancel);
  FOperationId := AOperationId;
  FGeneration := AGeneration;
  FKind := AKind;
  if AOperationId = InvalidBleOperationId then
    Complete(lbopFailed, LazBleErrorInvalidState,
      'Could not submit GATT operation');
end;

constructor TBleGattOperation.CreateCompleted(
  const AKind: TLazBleBackendCommandKind;
  const AState: TLazBleOperationState; const AErrorMessage: string);
begin
  inherited Create(nil);
  FOperationId := InvalidBleOperationId;
  FKind := AKind;
  if AState = lbopFailed then
    Complete(AState, LazBleErrorInvalidState, AErrorMessage)
  else
    Complete(AState, 0, AErrorMessage);
end;

destructor TBleGattOperation.Destroy;
begin
  FValue := nil;
  inherited Destroy;
end;

function TBleGattOperation.GetValue: TBytes;
begin
  LazBleRequireMainThread;
  Result := FValue;
end;

procedure TBleGattOperation.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  LazBleRequireMainThread;
  if (State <> lbopPending) or
    ((AEvent.Generation <> 0) and (AEvent.Generation <> FGeneration)) or
    (AEvent.OperationId <> FOperationId) then
    Exit;
  case AEvent.Kind of
    lbekReadResult:
      begin
        FValue := AEvent.Value;
      end;
    lbekOperationSucceeded:
      Complete(lbopSucceeded);
    lbekOperationFailed:
      Complete(lbopFailed, AEvent.ErrorCode, AEvent.ErrorMessage);
    lbekOperationCancelled:
      Complete(lbopCancelled);
  end;
end;

procedure TBleGattOperation.CancelLocally;
begin
  LazBleRequireMainThread;
  Complete(lbopCancelled);
end;

procedure TBleGattOperation.DetachOwner;
begin
  LazBleRequireMainThread;
  DetachCancelHandler;
end;

function TBleGattOperation.MatchesOperationId(
  const AOperationId: TBleOperationId): Boolean;
begin
  LazBleRequireMainThread;
  Result := FOperationId = AOperationId;
end;

function TBleGattOperation.GetOperationId: TBleOperationId;
begin
  LazBleRequireMainThread;
  Result := FOperationId;
end;

function TBleGattOperation.GetKind: TLazBleBackendCommandKind;
begin
  LazBleRequireMainThread;
  Result := FKind;
end;

end.
