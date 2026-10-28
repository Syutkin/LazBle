unit LazBleLclDemoForm;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  Forms,
  LazBleOperation,
  LazBleComponent,
  LazBleDeviceControl;

type
  TLazBleDemoForm = class(TForm)
    BleClient: TLazBleLclClient;
    BleDeviceControl: TLazBleDeviceControl;
    LazBle: TLazBleComponent;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  private
    FShutdown: IBleOperation;
    procedure ShutdownCompleted(Sender: TObject);
    procedure FinishClose(Data: PtrInt);
  public
    destructor Destroy; override;
  end;

var
  LazBleDemoForm: TLazBleDemoForm;

implementation

{$R *.lfm}

procedure TLazBleDemoForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := Assigned(FShutdown) and (FShutdown.State <> lbopPending);
  if CanClose or Assigned(FShutdown) then Exit;
  Enabled := False;
  FShutdown := LazBle.ShutdownAsync;
  FShutdown.OnCompleted := @ShutdownCompleted;
end;

procedure TLazBleDemoForm.ShutdownCompleted(Sender: TObject);
begin
  Application.QueueAsyncCall(@FinishClose, 0);
end;

procedure TLazBleDemoForm.FinishClose(Data: PtrInt);
begin
  Close;
end;

destructor TLazBleDemoForm.Destroy;
begin
  if Assigned(FShutdown) then FShutdown.OnCompleted := nil;
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

end.
