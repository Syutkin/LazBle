unit LazBleLclClientTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  FpcUnit,
  TestRegistry,
  LResources,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleComponent,
  FakeLazBleBackend;

type
  TClientStreamingOwner = class(TComponent)
  protected
    procedure GetChildren(Proc: TGetChildProc; Root: TComponent); override;
  published
    procedure ClientConnected(Sender: TObject);
    procedure ClientError(Sender: TObject; const AErrorCode: Integer;
      const AErrorMessage: string);
  end;

  TClientStreamingLazBleComponent = class(TLazBleComponent)
  protected
    function CreateFacade: TLazBle; override;
  end;

  TLazBleLclClientTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FLazBle: TLazBleComponent;
    FClient: TLazBleLclClient;
    FEventCount: Integer;
    procedure ClientEvent(Sender: TObject);
    procedure ClientError(Sender: TObject; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure FindComponentClass(Reader: TReader; const AClassName: string;
      var AClass: TComponentClass);
    function Device(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt): TBleDeviceInfo;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure StreamingRestoresLazBleDeviceIdAndEventsWithoutOperations;
    procedure SelectDeviceKeepsComponentAndEventHandlers;
    procedure DirectDeviceIdChangeClearsStaleDeviceName;
    procedure LazBleLinkClearsWhenComponentIsDestroyed;
  end;

implementation

var
  ClientStreamingBackend: ILazBleBackend;

procedure TClientStreamingOwner.GetChildren(Proc: TGetChildProc;
  Root: TComponent);
var
  Index: Integer;
begin
  for Index := 0 to ComponentCount - 1 do
    Proc(Components[Index]);
end;

procedure TClientStreamingOwner.ClientConnected(Sender: TObject);
begin
end;

procedure TClientStreamingOwner.ClientError(Sender: TObject;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
end;

function TClientStreamingLazBleComponent.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create(ClientStreamingBackend);
end;

procedure TLazBleLclClientTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FLazBle := TLazBleComponent.Create(nil, FBackend);
  FClient := TLazBleLclClient.Create(nil);
  FClient.LazBle := FLazBle;
end;

procedure TLazBleLclClientTest.TearDown;
begin
  FClient.Free;
  FClient := nil;
  FLazBle.Free;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleLclClientTest.ClientEvent(Sender: TObject);
begin
  Inc(FEventCount);
end;

procedure TLazBleLclClientTest.ClientError(Sender: TObject;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Inc(FEventCount);
end;

procedure TLazBleLclClientTest.FindComponentClass(Reader: TReader;
  const AClassName: string; var AClass: TComponentClass);
begin
  AClass := TComponentClass(GetClass(AClassName));
end;

function TLazBleLclClientTest.Device(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt): TBleDeviceInfo;
begin
  Result := Default(TBleDeviceInfo);
  Result.DeviceId := ADeviceId;
  Result.DeviceName := ADeviceName;
  Result.Rssi := ARssi;
end;

procedure TLazBleLclClientTest.StreamingRestoresLazBleDeviceIdAndEventsWithoutOperations;
var
  Backend: ILazBleBackend;
  BackendObject: TFakeLazBleBackend;
  Loaded: TComponent;
  LoadedClient: TLazBleLclClient;
  LoadedLazBle: TClientStreamingLazBleComponent;
  LoadedOwner: TClientStreamingOwner;
  Owner: TClientStreamingOwner;
  SourceClient: TLazBleLclClient;
  SourceLazBle: TClientStreamingLazBleComponent;
  Stream: TMemoryStream;
begin
  FClient.Free;
  FClient := nil;
  FLazBle.Free;
  FLazBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  BackendObject := TFakeLazBleBackend.Create;
  Backend := BackendObject;
  ClientStreamingBackend := Backend;
  Owner := TClientStreamingOwner.Create(nil);
  Owner.Name := 'StreamingOwner';
  LoadedOwner := nil;
  Stream := TMemoryStream.Create;
  try
    SourceLazBle := TClientStreamingLazBleComponent.Create(Owner);
    SourceLazBle.Name := 'LazBle1';
    SourceClient := TLazBleLclClient.Create(Owner);
    SourceClient.Name := 'BleClient1';
    SourceClient.LazBle := SourceLazBle;
    SourceClient.DeviceId := 'streamed-device';
    SourceClient.OnConnected := @Owner.ClientConnected;
    SourceClient.OnError := @Owner.ClientError;
    WriteComponentAsTextToStream(Stream, Owner);
    Owner.Free;
    Owner := nil;

    Stream.Position := 0;
    Loaded := nil;
    ReadComponentFromTextStream(Stream, Loaded, @FindComponentClass);
    LoadedOwner := Loaded as TClientStreamingOwner;
    LoadedLazBle := LoadedOwner.FindComponent('LazBle1') as
      TClientStreamingLazBleComponent;
    LoadedClient := LoadedOwner.FindComponent('BleClient1') as
      TLazBleLclClient;

    AssertSame(LoadedLazBle, LoadedClient.LazBle);
    AssertEquals(1, LoadedLazBle.ClientCount);
    AssertSame(LoadedClient, LoadedLazBle.Clients[0]);
    AssertEquals('streamed-device', LoadedClient.DeviceId);
    AssertEquals('', LoadedClient.DeviceName);
    AssertTrue(TMethod(LoadedClient.OnConnected).Code =
      TMethod(@LoadedOwner.ClientConnected).Code);
    AssertTrue(TMethod(LoadedClient.OnConnected).Data =
      TMethod(@LoadedOwner.ClientConnected).Data);
    AssertTrue(TMethod(LoadedClient.OnError).Code =
      TMethod(@LoadedOwner.ClientError).Code);
    AssertTrue(TMethod(LoadedClient.OnError).Data =
      TMethod(@LoadedOwner.ClientError).Data);
    AssertEquals(0, BackendObject.CommandCount);
  finally
    Stream.Free;
    LoadedOwner.Free;
    Owner.Free;
    ClientStreamingBackend := nil;
    Backend := nil;
  end;
end;

procedure TLazBleLclClientTest.SelectDeviceKeepsComponentAndEventHandlers;
var
  ClientIdentity: Pointer;
  ConnectedHandler: TNotifyEvent;
  ErrorHandler: TLazBleLclErrorEvent;
begin
  FClient.OnConnected := @ClientEvent;
  FClient.OnError := @ClientError;
  ClientIdentity := Pointer(FClient);
  ConnectedHandler := FClient.OnConnected;
  ErrorHandler := FClient.OnError;

  FClient.SelectDevice(Device('device-42', 'Timing unit', -37));

  AssertTrue(ClientIdentity = Pointer(FClient));
  AssertEquals('device-42', FClient.DeviceId);
  AssertEquals('Timing unit', FClient.DeviceName);
  AssertTrue(TMethod(FClient.OnConnected).Code =
    TMethod(ConnectedHandler).Code);
  AssertTrue(TMethod(FClient.OnConnected).Data =
    TMethod(ConnectedHandler).Data);
  AssertTrue(TMethod(FClient.OnError).Code = TMethod(ErrorHandler).Code);
  AssertTrue(TMethod(FClient.OnError).Data = TMethod(ErrorHandler).Data);
  AssertEquals(0, FEventCount);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleLclClientTest.DirectDeviceIdChangeClearsStaleDeviceName;
begin
  FClient.SelectDevice(Device('device-a', 'Old name', -50));

  FClient.DeviceId := 'device-b';

  AssertEquals('device-b', FClient.DeviceId);
  AssertEquals('', FClient.DeviceName);
  AssertEquals(0, FBackendObject.CommandCount);
end;

procedure TLazBleLclClientTest.LazBleLinkClearsWhenComponentIsDestroyed;
begin
  FLazBle.Free;
  FLazBle := nil;

  AssertNull(FClient.LazBle);
end;

initialization
  RegisterClass(TClientStreamingOwner);
  RegisterClass(TClientStreamingLazBleComponent);
  RegisterTest(TLazBleLclClientTest);

finalization
  UnregisterClass(TClientStreamingLazBleComponent);
  UnregisterClass(TClientStreamingOwner);

end.
