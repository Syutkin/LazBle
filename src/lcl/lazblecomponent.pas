unit LazBleComponent;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleLclScan;

const
  DefaultLazBleScanTimeoutMs = 10000;

type
  TLazBleLclErrorEvent = procedure(Sender: TObject; const AErrorCode: Integer;
    const AErrorMessage: string) of object;

  TLazBleComponent = class(TComponent)
  private
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FAdapterId: string;
    FScanTimeoutMs: Cardinal;
    FOnScanStateChanged: TLazBleLclScanStateChangedEvent;
    FOnScanResult: TLazBleScanResultEvent;
    FOnScanCompleted: TLazBleLclScanCompletedEvent;
    FOnError: TLazBleLclErrorEvent;
    procedure Initialize(const ABle: TLazBle);
    function GetScanState: TLazBleLclScanState;
    function GetScanResults: TBleDeviceInfos;
    function GetLastErrorCode: Integer;
    function GetLastErrorMessage: string;
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
  protected
    function CreateFacade: TLazBle; virtual;
  public
    constructor Create(AOwner: TComponent); override; overload;
    constructor Create(AOwner: TComponent;
      const ABackend: ILazBleBackend); reintroduce; overload;
    destructor Destroy; override;
    procedure StartScan;
    procedure CancelScan;
    procedure ClearScanResults;
    property ScanState: TLazBleLclScanState read GetScanState;
    property ScanResults: TBleDeviceInfos read GetScanResults;
    property LastErrorCode: Integer read GetLastErrorCode;
    property LastErrorMessage: string read GetLastErrorMessage;
    property Facade: TLazBle read FBle;
  published
    property AdapterId: string read FAdapterId write FAdapterId;
    property ScanTimeoutMs: Cardinal read FScanTimeoutMs write FScanTimeoutMs
      default DefaultLazBleScanTimeoutMs;
    property OnScanStateChanged: TLazBleLclScanStateChangedEvent
      read FOnScanStateChanged write FOnScanStateChanged;
    property OnScanResult: TLazBleScanResultEvent
      read FOnScanResult write FOnScanResult;
    property OnScanCompleted: TLazBleLclScanCompletedEvent
      read FOnScanCompleted write FOnScanCompleted;
    property OnError: TLazBleLclErrorEvent read FOnError write FOnError;
  end;

implementation

constructor TLazBleComponent.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScanTimeoutMs := DefaultLazBleScanTimeoutMs;
  Initialize(CreateFacade);
end;

constructor TLazBleComponent.Create(AOwner: TComponent;
  const ABackend: ILazBleBackend);
begin
  inherited Create(AOwner);
  if not Assigned(ABackend) then
    raise EArgumentNilException.Create('ABackend');
  FScanTimeoutMs := DefaultLazBleScanTimeoutMs;
  Initialize(TLazBle.Create(ABackend));
end;

destructor TLazBleComponent.Destroy;
begin
  if Assigned(FScan) then
  begin
    FScan.OnStateChanged := nil;
    FScan.OnResult := nil;
    FScan.OnCompleted := nil;
  end;
  FScan.Free;
  FScan := nil;
  FBle.Free;
  FBle := nil;
  inherited Destroy;
end;

function TLazBleComponent.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create;
end;

procedure TLazBleComponent.Initialize(const ABle: TLazBle);
begin
  FBle := ABle;
  FScan := TLazBleLclScan.Create(FBle);
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnResult := @ScanResult;
  FScan.OnCompleted := @ScanCompleted;
end;

procedure TLazBleComponent.StartScan;
begin
  FScan.Start(FAdapterId, FScanTimeoutMs);
end;

procedure TLazBleComponent.CancelScan;
begin
  FScan.Cancel;
end;

procedure TLazBleComponent.ClearScanResults;
begin
  FScan.ClearResults;
end;

function TLazBleComponent.GetScanState: TLazBleLclScanState;
begin
  Result := FScan.State;
end;

function TLazBleComponent.GetScanResults: TBleDeviceInfos;
begin
  Result := FScan.Results;
end;

function TLazBleComponent.GetLastErrorCode: Integer;
begin
  Result := FScan.ErrorCode;
end;

function TLazBleComponent.GetLastErrorMessage: string;
begin
  Result := FScan.ErrorMessage;
end;

procedure TLazBleComponent.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Handler: TLazBleLclScanStateChangedEvent;
begin
  Handler := FOnScanStateChanged;
  if Assigned(Handler) then
    Handler(Self, AState);
end;

procedure TLazBleComponent.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  Handler: TLazBleScanResultEvent;
begin
  Handler := FOnScanResult;
  if Assigned(Handler) then
    Handler(Self, ADeviceId, ADeviceName, ARssi);
end;

procedure TLazBleComponent.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  CompletedHandler: TLazBleLclScanCompletedEvent;
  ErrorHandler: TLazBleLclErrorEvent;
begin
  if AState in [lblssTimedOut, lblssFailed] then
  begin
    ErrorHandler := FOnError;
    if Assigned(ErrorHandler) then
      ErrorHandler(Self, FScan.ErrorCode, FScan.ErrorMessage);
  end;

  CompletedHandler := FOnScanCompleted;
  if Assigned(CompletedHandler) then
    CompletedHandler(Self, AState);
end;

initialization
  RegisterClass(TLazBleComponent);

finalization
  UnregisterClass(TLazBleComponent);

end.
