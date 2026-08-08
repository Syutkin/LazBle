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

  TLazBleOperationCompletedEvent = procedure(Sender: TObject) of object;

  TBleGattOperation = class
  private
    FOperationId: TBleOperationId;
    FKind: TLazBleBackendCommandKind;
    FState: TLazBleOperationState;
    FValue: TBytes;
    FErrorCode: Integer;
    FErrorMessage: string;
    FOnCompleted: TLazBleOperationCompletedEvent;
    procedure NotifyCompleted;
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
    property OnCompleted: TLazBleOperationCompletedEvent read FOnCompleted
      write FOnCompleted;
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

procedure TBleGattOperation.NotifyCompleted;
var
  CompletedHandler: TLazBleOperationCompletedEvent;
begin
  CompletedHandler := FOnCompleted;
  FOnCompleted := nil;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self);
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
      begin
        FState := lbosSucceeded;
        NotifyCompleted;
      end;
    lbekOperationFailed:
      begin
        FState := lbosFailed;
        FErrorCode := AEvent.ErrorCode;
        FErrorMessage := AEvent.ErrorMessage;
        NotifyCompleted;
      end;
    lbekOperationCancelled:
      begin
        FState := lbosCancelled;
        NotifyCompleted;
      end;
  end;
end;

procedure TBleGattOperation.CancelLocally;
begin
  if FState = lbosPending then
  begin
    FState := lbosCancelled;
    NotifyCompleted;
  end;
end;

end.
