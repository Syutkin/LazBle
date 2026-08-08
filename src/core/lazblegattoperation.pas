unit LazBleGattOperation;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  LazBleTypes;

type
  TLazBleOperationState = (
    lbosPending,
    lbosSucceeded,
    lbosFailed,
    lbosCancelled
  );

  TBleGattOperation = class
  private
    FOperationId: TBleOperationId;
    FKind: TLazBleBackendCommandKind;
    FState: TLazBleOperationState;
    FValue: TBytes;
    FErrorCode: Integer;
    FErrorMessage: string;
  public
    constructor Create(const AOperationId: TBleOperationId;
      const AKind: TLazBleBackendCommandKind);
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
    procedure CancelLocally;
    property OperationId: TBleOperationId read FOperationId;
    property Kind: TLazBleBackendCommandKind read FKind;
    property State: TLazBleOperationState read FState;
    property Value: TBytes read FValue;
    property ErrorCode: Integer read FErrorCode;
    property ErrorMessage: string read FErrorMessage;
  end;

implementation

constructor TBleGattOperation.Create(const AOperationId: TBleOperationId;
  const AKind: TLazBleBackendCommandKind);
begin
  inherited Create;
  FOperationId := AOperationId;
  FKind := AKind;
  if AOperationId = InvalidBleOperationId then
    FState := lbosFailed
  else
    FState := lbosPending;
end;

procedure TBleGattOperation.HandleBackendEvent(
  const AEvent: TLazBleBackendEvent);
begin
  if (FState <> lbosPending) or
    (AEvent.OperationId <> FOperationId) then
    Exit;
  case AEvent.Kind of
    lbekReadResult:
      FValue := Copy(AEvent.Value);
    lbekOperationSucceeded:
      FState := lbosSucceeded;
    lbekOperationFailed:
      begin
        FState := lbosFailed;
        FErrorCode := AEvent.ErrorCode;
        FErrorMessage := AEvent.ErrorMessage;
      end;
    lbekOperationCancelled:
      FState := lbosCancelled;
  end;
end;

procedure TBleGattOperation.CancelLocally;
begin
  if FState = lbosPending then
    FState := lbosCancelled;
end;

end.
