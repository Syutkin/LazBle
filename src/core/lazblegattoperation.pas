unit LazBleGattOperation;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes,
  LazBleOperation;

type
  IBleGattOperation = interface(IBleOperation)
    ['{88355E9C-04D6-46E7-9B3E-6E3470C9E980}']
    function GetValue: TBytes;
    property Value: TBytes read GetValue;
  end;

  TBleGattOperation = class(TBleOperation, IBleGattOperation)
  private
    FValueLock: TRTLCriticalSection;
    FOperationId: TBleOperationId;
    FKind: TLazBleBackendCommandKind;
    FValue: TBytes;
    function GetValue: TBytes;
  protected
    constructor Create(const AOperationId: TBleOperationId;
      const AKind: TLazBleBackendCommandKind;
      const AOnCancel: TLazBleOperationCancelEvent);
    constructor CreateCompleted(const AKind: TLazBleBackendCommandKind;
      const AState: TLazBleOperationState;
      const AErrorMessage: string = '');
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure CancelLocally;
    procedure DetachOwner;
    function MatchesOperationId(const AOperationId: TBleOperationId): Boolean;
    function GetOperationId: TBleOperationId;
    function GetKind: TLazBleBackendCommandKind;
  public
    destructor Destroy; override;
    property Value: TBytes read GetValue;
  end;

implementation

constructor TBleGattOperation.Create(const AOperationId: TBleOperationId;
  const AKind: TLazBleBackendCommandKind;
  const AOnCancel: TLazBleOperationCancelEvent);
begin
  inherited Create(AOnCancel);
  InitCriticalSection(FValueLock);
  FOperationId := AOperationId;
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
  InitCriticalSection(FValueLock);
  FOperationId := InvalidBleOperationId;
  FKind := AKind;
  if AState = lbopFailed then
    Complete(AState, LazBleErrorInvalidState, AErrorMessage)
  else
    Complete(AState, 0, AErrorMessage);
end;

destructor TBleGattOperation.Destroy;
begin
  EnterCriticalSection(FValueLock);
  try
    FValue := nil;
  finally
    LeaveCriticalSection(FValueLock);
  end;
  DoneCriticalSection(FValueLock);
  inherited Destroy;
end;

function TBleGattOperation.GetValue: TBytes;
begin
  EnterCriticalSection(FValueLock);
  try
    Result := Copy(FValue);
  finally
    LeaveCriticalSection(FValueLock);
  end;
end;

procedure TBleGattOperation.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if (State <> lbopPending) or
    (AEvent.OperationId <> FOperationId) then
    Exit;
  case AEvent.Kind of
    lbekReadResult:
      begin
        EnterCriticalSection(FValueLock);
        try
          FValue := Copy(AEvent.Value);
        finally
          LeaveCriticalSection(FValueLock);
        end;
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
  Complete(lbopCancelled);
end;

procedure TBleGattOperation.DetachOwner;
begin
  DetachCancelHandler;
end;

function TBleGattOperation.MatchesOperationId(
  const AOperationId: TBleOperationId): Boolean;
begin
  Result := FOperationId = AOperationId;
end;

function TBleGattOperation.GetOperationId: TBleOperationId;
begin
  Result := FOperationId;
end;

function TBleGattOperation.GetKind: TLazBleBackendCommandKind;
begin
  Result := FKind;
end;

end.
