unit LazBleBackend;

{$mode objfpc}{$H+}

interface

uses
  LazBleTypes;

type
  ILazBleBackendEventSink = interface
    ['{1F4A66C4-5739-4428-902D-B09F59039602}']
    procedure HandleBackendEvent(const AEvent: TLazBleBackendEvent);
  end;

  { Backend contract. Submit returns an operation ID; progress and terminal
    events are delivered through the installed sink. A custom backend must
    implement every method, including GetBackendName. }
  ILazBleBackend = interface
    ['{80466D51-799E-42D1-95F0-CBD15178B223}']
    { Identity supplied by this backend implementation. The getter must not
      open a native library or start BLE work; return an empty string if the
      name is not yet known. }
    function GetBackendName: string;
    { The sink may be detached during shutdown; do not deliver events after
      detachment has completed. }
    procedure SetEventSink(const AEventSink: ILazBleBackendEventSink);
    { Return InvalidBleOperationId when a command cannot be started. }
    function Submit(const ACommand: TLazBleBackendCommand): TBleOperationId;
    procedure Cancel(const AOperationId: TBleOperationId);
    { Begin orderly backend shutdown and return its operation ID. }
    function BeginShutdown: TBleOperationId;
  end;

implementation

end.
