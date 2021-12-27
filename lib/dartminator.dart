import 'dart:convert' show utf8;
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:async';

import 'package:grpc/grpc.dart';

import 'package:dartminator/generated/dartminator.pbgrpc.dart';

import 'computation.dart';
import 'constants.dart';
import 'logger.dart';

class DartminatorNode extends NodeServiceBase {
  /// Logger instance.
  var logger = getLogger();

  /// Name of the node, usually automatically generated by Faker.
  String name;

  /// Port to be discovered/discover child nodes on.
  int discoveryPort;

  /// Upper limit of possible child connections.
  int maxChildren;

  /// Amount of chunks remaining to be calculated.
  int _remaining = 0;

  /// List of the current child nodes.
  final List<io.InternetAddress> _children = [];

  /// Type of the computation
  final Computation _computation;

  /// Is the current node in a computation?
  bool _isComputing = false;

  DartminatorNode(
      this.name, this.discoveryPort, this.maxChildren, this._computation) {
    logger.i('Created Node $name for the ${_computation.name} computation.');
  }

  /// Initializes the node to be used on the network.
  ///
  /// Prepares the node to be used over the local network for computation.
  /// This means listening for incoming connections to a computation.
  Future init() async {
    await listenForConnections();
  }

  /// Starts the computation on this node and redistributes arguments to child nodes.
  ///
  /// Starts the computation as the root node.
  ///
  /// [seed] is the starting argument for the computation.
  ///
  /// Returns the result of the computation.
  Future<String> start(String seed) async {
    logger.i('Starting the computation with seed $seed.');

    var results = await compute(_computation.getArguments(seed));
    var composed = await _computation.finalizeResult(results);

    logger
        .i('All of the computations are completed. The result is: $composed.');

    return composed;
  }

  /// Computes all of the results on this node and potential child nodes.
  ///
  /// [arguments] is the list of arguments to compute through.
  ///
  /// Returns the list of results from this and child nodes.
  ///
  /// The computation assigns work to this node and any potential nodes until
  /// the all of the arguments are processed. In case of a node failure, the
  /// argument is reassigned to another node.
  ///
  /// Child nodes are searched for during each assignment cycle. This has to be
  /// done because the child node detaches itself from the tree as a leaf.
  /// The tree has to be then reconstructed with the same or even different nodes.
  Future<List<String>> compute(List<String> arguments) async {
    logger.i('Starting the computation of ${arguments.length} chunks.');
    _isComputing = true;

    // The result array is generated with empty strings.
    var results = List<String>.generate(arguments.length, (_index) => '');

    // The counter of completed chunks.
    var completed = 0;

    // Runs until all arguments are processed.
    while (completed < arguments.length) {
      // List of workers for the current iteration.
      var workers = <Future<String?>>[];

      // A check for available argument is run due to concurrency possibly
      // finishing after the start of the cycle.
      var index = results.lastIndexWhere((element) => element.isEmpty);
      if (index > -1) {
        ReceivePort mainPort = ReceivePort();

        Map<String, dynamic> mainData = {};
        mainData['port'] = mainPort.sendPort;
        mainData['argument'] = arguments[index];
        mainData['computation'] = _computation;

        // Worker listens for the result on the [mainPort] of the Isolate.
        workers.add(mainPort.listen((data) {
          // Registers the result
          results[index] = data ?? '';
          completed = results.where((element) => element.isNotEmpty).length;

          // Closes the Isolate port to prevent any possible memory/process issues.
          mainPort.close();
        }).asFuture<String?>());

        // Starts a new Isolate for the current node computation
        await Isolate.spawn(handleMainComputation, mainData);
      }

      // If there is a space for children, new ones are added.
      // Subtracting one since the main node takes one argument for itself.
      var childLimit =
          (results.where((element) => element.isEmpty).length - 1) < maxChildren
              ? (results.where((element) => element.isEmpty).length - 1)
              : maxChildren;

      // Chunks are assigned to children only if there are any available.
      if (_children.length < childLimit) {
        logger.i('Redistributing the computation to child nodes.');

        // Looks for children until the timeout is reached
        await findChildren(childLimit).timeout(
          childSearchTimeout,
          onTimeout: () {
            logger.d(
                'The child search has finished with ${_children.length} child nodes.');
          },
        );

        // Assigns arguments until all child nodes are working
        for (var i = 0; i < _children.length; ++i) {
          // A check for available argument is run due to concurrency possibly
          // finishing after the start of the assignment cycle.
          var index = results.lastIndexWhere((element) => element.isEmpty);
          if (index > -1) {
            var port = ReceivePort();

            Map<String, dynamic> data = {};
            var child = _children[i];
            data['port'] = port.sendPort;
            data['child'] = child;
            data['argument'] = arguments[index];

            workers.add(port.listen((data) {
              // Registers the result.
              results[index] = data ?? '';
              completed = results.where((element) => element.isNotEmpty).length;

              // Removes the child from the list.
              _children.remove(child);

              logger.d(
                  'The computation of child $child has finished with $data.');

              // Closes the port to prevent possible memory/process issues.
              port.close();
            }).asFuture<String?>());

            // Starts a new Isolate to handle the child connection
            await Isolate.spawn(handleChildComputation, data);
          }
        }
      }

      // Waits for all of the workers to complete their computation.
      await Future.wait(workers);

      _remaining = arguments.length - completed;
      logger.i('Finished computation cycle. $_remaining chunk(s) remaining.');
    }

    _isComputing = false;
    return results;
  }

  /// Tries to find a child nodes for the computation on the local network.
  ///
  /// [limit] upper limit of the children to register.
  ///
  /// Sends out a broadcast message over the local network with a computation invite.
  /// Any responder that is not this node and is not already registered as a child
  /// is added to the list. The listening port is closed after reaching [limit].
  Future findChildren(int limit) async {
    logger.d('Starting the search for children.');

    // Socket used to send and receive messages
    // Port 0 is used to prevent clashes with the discoveryPort
    var socket = await io.RawDatagramSocket.bind(io.InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    socket.readEventsEnabled = true;

    // A stream handling the communication with potential children.
    // asFuture is used to synchronize the behavior with other async functions.
    var stream = socket.listen((event) {
      try {
        if (event == io.RawSocketEvent.read) {
          var response = socket.receive();

          if (response != null) {
            var responderName =
                utf8.decode(response.data).split('-')[1].split('Name')[1];

            logger.d(
                'Child Search: Got response from $responderName at ${response.address}');

            // Prevents from connecting to self
            // To already connected node
            // Or reaching the connection limit
            if (responderName != name &&
                !_children.contains(response.address) &&
                _children.length < maxChildren) {
              logger.d(
                  'Adding $responderName at ${response.address} to children!');

              _children.add(response.address);

              // Closes the socket as it is not needed anymore.
              if (_children.length >= limit) {
                socket.close();
              }
            }
          }
        }
      } catch (err, stacktrace) {
        logger.e('Could not parse incoming message!\n$err\n$stacktrace');
      }
    }).asFuture();

    // Sends out the broadcast message with it's own name as a computation invitation.
    socket.send(
        'Dartminator-Name$name-Computation${_computation.name}'.codeUnits,
        io.InternetAddress("255.255.255.255"),
        discoveryPort);

    // Waits for the stream to finish.
    await stream;
  }

  /// Starts listening to potential computations.
  ///
  /// Starts a socket listening to possible computation invitations on [discoveryPort].
  /// Any response incoming from a node with a different name is responded to.
  Future listenForConnections() async {
    // Socket used exclusively for listening to computation invites.
    var socket = await io.RawDatagramSocket.bind(
        io.InternetAddress.anyIPv4, discoveryPort);
    socket.readEventsEnabled = true;

    logger.i('Listening for potential computation on port $discoveryPort.');

    socket.listen((event) {
      try {
        if (event == io.RawSocketEvent.read) {
          var response = socket.receive();

          if (response != null) {
            logger.d(
                'Computation listening response: ${utf8.decode(response.data)}');

            // Checks the inviters name and computation type
            var inviter =
                utf8.decode(response.data).split('-')[1].split('Name')[1];
            var computation = utf8
                .decode(response.data)
                .split('-')[2]
                .split('Computation')[1];

            if (inviter != name && computation == _computation.name) {
              logger.d(
                  'Found a new potential computation from $inviter at ${response.address}.');

              socket.send('Dartminator-Name$name'.codeUnits, response.address,
                  response.port);
            }
          }
        }
      } catch (err, stacktrace) {
        logger.e(
            'Could not parse response during computation listening!\n$err\n$stacktrace');
      }
    });
  }

  /// Handles the gRPC communication with a child node.
  ///
  /// [data] is a map of the arguments. A map is used due to the limitations of
  /// Isolates. [data] consists of: a ReceivePort used for communication with the
  /// parent Isolate, InternetAddress of the child to communicate with and the
  /// argument the child will use during the computation.
  ///
  /// Opens a gRPC channel with the child and handles the stream of responses.
  /// In case the child is already in another computation or the connection fails,
  /// null is sent back to the main Isolate through the port. Otherwise the handler
  /// waits for the result of the computation and returns it through the port.
  static Future handleChildComputation(Map<String, dynamic> data) async {
    // A separate logger instance is needed since Isolates do not have access
    // to closure and memory of the parent Isolate.
    var logger = getLogger();

    SendPort port = data['port'];

    try {
      logger.d('Started child handler for ${data['child']}.');

      // Creates the gRPC channel on the port 50051 with no credentials
      ClientChannel clientChannel = ClientChannel(data['child'],
          port: grpcPort,
          options: ChannelOptions(
              credentials: ChannelCredentials.insecure(),
              connectionTimeout: grpcCallTimeout));

      // Creates the Dartminator Node stub to use for communication
      NodeClient child = NodeClient(clientChannel,
          options: CallOptions(timeout: grpcCallTimeout));

      String? result;
      var responses =
          child.initiate(ComputationArgument(argument: data['argument']));

      // Listens to the response stream from the child node
      await for (var response in responses) {
        logger.d('Response from child ${data['child']}: $response');

        if (response.empty) {
          logger.w('The child ${data['child']} is already in a computation!');
          break;
        }

        if (response.result.done) {
          logger.d(
              'The child ${data['child']} has finished with ${response.result.result}.');

          result = response.result.result;
          break;
        }
      }

      // Shuts the gRPC channel gracefully.
      await clientChannel.shutdown();

      port.send(result);
    } catch (err, stacktrace) {
      logger.e('The connection with a child has failed!\n$err\n$stacktrace');

      port.send(null);
    }
  }

  /// Handles the main computation.
  ///
  /// [data] is a map of the arguments. A map is used due to the limitations of
  /// Isolates. [data] consists of: a ReceivePort used for communication with the
  /// parent Isolate, the Computation object, and the argument the child will
  ///  use during the computation.
  ///
  /// Starts the computation and awaits its completion. In case of a failure,
  /// a null is sent back to the main Isolate.
  static Future handleMainComputation(Map<String, dynamic> data) async {
    // A separate logger instance is needed since Isolates do not have access
    // to closure and memory of the parent Isolate.
    var logger = getLogger();

    SendPort port = data['port'];
    Computation computation = data['computation'];

    try {
      logger.d(
          'Starting main node computation from the argument ${data['argument']}.');

      var result = await computation.compute(data['argument']);

      logger
          .d('This node\'s computation has completed with the result $result.');

      port.send(result);
    } catch (err, stacktrace) {
      logger.e('The main computation has thrown an error!\n$err\n$stacktrace');

      port.send(null);
    }
  }

  /// Implements the gRPC function for communication between nodes.
  @override
  Stream<ComputationHeartbeat> initiate(
      ServiceCall call, ComputationArgument request) async* {
    logger.d('Heartbeat request: $request');

    // The node is already working. Returns an empty response.
    if (_isComputing) {
      logger.i(
          'Received a heartbeat request while in a computation. Returning empty response.');

      yield ComputationHeartbeat(empty: true);
    }

    logger.i('Starting the computation as a child.');
    String? result;
    compute(_computation.getArguments(request.argument)).then((results) async {
      result = await _computation.finalizeResult(results);
    });

    // Returns a heartbeat until the computation is finished.
    // The delay between heartbeats is set by calculationTimeout.
    while (result == null) {
      logger.i(
          'Still computing. Returning an empty heartbeat and waiting for $heartbeatTimeout.');

      var response = await Future.delayed(heartbeatTimeout,
          () => ComputationHeartbeat(result: ComputationResult(done: false)));
      yield response;
    }

    logger.i('Finished computation. Returning heartbeat with the result.');
    logger.i('Listening to new computation connections.');

    // The computation has finished. Returning the result.
    yield ComputationHeartbeat(
        result: ComputationResult(done: true, result: result));
  }

  /// Exposes the computing status.
  bool isComputing() => _isComputing;

  /// Exposes the count of currently connected children.
  int connectedChildren() => _children.length;

  /// Exposes the count of remaining chunks of a computation.
  int remainingChunks() => _remaining;
}
