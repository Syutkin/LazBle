unit LazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LazBleTypes;

type
  TLazBleRequestStatus = (lbrsSucceeded, lbrsFailed, lbrsCancelled);

  { One immutable terminal snapshot. Status, not error code/text, determines
    the outcome. Payloads are read-only managed data. }
  TLazBleRequestResult = record
    Status: TLazBleRequestStatus;
    ErrorCode: Integer;
    ErrorMessage: string;
    Value: TBytes;
    Services: TLazBleGattServices;
    ScanResults: TBleDeviceInfos;
    SubscriptionId: TBleSubscriptionId;
    Available: Boolean;
    BackendName, BackendVersion, AdapterId: string;
  end;

  ILazBleRequestCompletion = interface
    ['{037F83CB-AF54-4EF2-8578-C20AA20E1A53}']
    procedure CompleteRequest(const AResult: TLazBleRequestResult);
  end;

  ILazBleBackendEventSink = interface
    ['{1F4A66C4-5739-4428-902D-B09F59039602}']
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  { Main-thread API and sink delivery, including custom/fake backends. Submit
    and BeginShutdown must return before any corresponding event is delivered.
    Exactly one terminal event is required for each accepted command. Cancel
    requests best effort; started commands report their actual outcome. Shutdown
    drains commands before its terminal event (ShutdownFailed reports cleanup
    failure, including native code 0 and empty text), then delivers no more events. Backends
    copy write buffers at Submit. Snapshots/payloads are read-only managed data.
    Async callers pump the main loop/CheckSynchronize, never wait inside a sink
    callback, and defer owner destruction from callbacks with ForceQueue. }
  ILazBleBackend = interface
    ['{80466D51-799E-42D1-95F0-CBD15178B223}']
    { Identity supplied by this backend implementation. The getter must not
      start BLE work; return an empty string if the
      name is not yet known. }
    function GetBackendName: string;
    { The sink may be detached during shutdown; do not deliver events after
      detachment has completed. }
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    { Return InvalidBleOperationId when a command cannot be started. }
    function Submit(const ACommand: TLazBleBackendCommand;
      const ACompletion: ILazBleRequestCompletion = nil): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    { Begin orderly backend shutdown and return its operation ID. }
    function BeginShutdown: TBleOperationId;
  end;

implementation

end.
