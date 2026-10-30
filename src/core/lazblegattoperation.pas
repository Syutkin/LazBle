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

  TBleGattOperation = class(TBleOperation, IBleGattOperation)
  private
    FOperationId: TBleOperationId;
    FGeneration: QWord;
    FKind: TLazBleBackendCommandKind;
    FValue: TBytes;
    function GetValue: TBytes;
  protected
    constructor CreateRequest(const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord);
    procedure BindRequest(const AOperationId: TBleOperationId);
    { A local operation that awaits a chained native cleanup. }
    constructor CreatePending(const AKind: TLazBleBackendCommandKind);
    constructor CreateCompleted(const AKind: TLazBleBackendCommandKind;
      const AState: TLazBleOperationState; const AErrorMessage: string = '');
    procedure CompleteRequest(const AResult: TLazBleRequestResult); override;
    procedure CancelLocally;
    procedure DetachOwner;
    function GetOperationId: TBleOperationId;
    function GetKind: TLazBleBackendCommandKind;
    property OperationGeneration: QWord read FGeneration;
  public
    destructor Destroy; override;
    property Value: TBytes read GetValue;
  end;

implementation

constructor TBleGattOperation.CreateCompleted(const AKind: TLazBleBackendCommandKind;
  const AState: TLazBleOperationState; const AErrorMessage: string);
begin
  inherited Create(nil);
  FKind := AKind;
  if AState = lbopFailed then Complete(AState, LazBleErrorInvalidState, AErrorMessage)
  else Complete(AState, 0, AErrorMessage);
end;

constructor TBleGattOperation.CreateRequest(const AKind: TLazBleBackendCommandKind;
  const AOnCancel: TLazBleOperationCancelEvent; const AGeneration: QWord);
begin
  inherited Create(AOnCancel);
  FKind := AKind;
  FGeneration := AGeneration;
end;

procedure TBleGattOperation.BindRequest(const AOperationId: TBleOperationId);
begin
  FOperationId := AOperationId;
  if AOperationId = InvalidBleOperationId then
    Complete(lbopFailed, LazBleErrorInvalidState, 'Could not submit GATT operation');
end;

procedure TBleGattOperation.CompleteRequest(const AResult: TLazBleRequestResult);
begin
  LazBleRequireMainThread;
  if State <> lbopPending then Exit;
  FValue := AResult.Value;
  inherited CompleteRequest(AResult);
end;

constructor TBleGattOperation.CreatePending(const AKind: TLazBleBackendCommandKind);
begin
  inherited Create(nil);
  FKind := AKind;
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

procedure TBleGattOperation.CancelLocally;
begin
  LazBleRequireMainThread;
  Complete(lbopCancelled);
end;

procedure TBleGattOperation.DetachOwner;
begin
  LazBleRequireMainThread;
  DetachCancelHandler;
  OnFinishing := nil;
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
