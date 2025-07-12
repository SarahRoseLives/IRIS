import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import '../models/irc_network.dart'; // Corrected import
import '../services/api_service.dart'; // Import ApiService for fetching details
// No need for provider here if we pass ChatController directly
import '../controllers/chat_controller.dart'; // Import ChatController

class EditIrcServerScreen extends StatefulWidget {
  final IrcNetwork network; // This initial network might be incomplete
  final ChatController chatController; // ADD THIS LINE

  const EditIrcServerScreen({
    super.key,
    required this.network,
    required this.chatController, // ADD THIS LINE
  });

  @override
  State<EditIrcServerScreen> createState() => _EditIrcServerScreenState();
}

class _EditIrcServerScreenState extends State<EditIrcServerScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _networkNameController;
  late TextEditingController _hostnameController;
  late TextEditingController _portController;
  late TextEditingController _serverPasswordController;
  late TextEditingController _nicknameController;
  late TextEditingController _altNicknameController;
  late TextEditingController _identController;
  late TextEditingController _realnameController;
  late TextEditingController _quitMessageController;
  late TextEditingController _performCommandsController;
  late TextEditingController _initialChannelsController;

  late bool _useSsl;
  late bool _autoReconnect;
  late Map<String, bool> _modules;

  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _networkNameController = TextEditingController();
    _hostnameController = TextEditingController();
    _portController = TextEditingController(text: '6667');
    _serverPasswordController = TextEditingController();
    _nicknameController = TextEditingController();
    _altNicknameController = TextEditingController();
    _identController = TextEditingController();
    _realnameController = TextEditingController();
    _quitMessageController = TextEditingController();
    _performCommandsController = TextEditingController();
    _initialChannelsController = TextEditingController();

    _useSsl = false;
    _autoReconnect = true;
    _modules = {
      'sasl': false,
      'nickserv': false,
      'keepnick': false,
      'kickrejoin': false,
      'perform': false,
    };

    _fetchNetworkDetails();
  }

  Future<void> _fetchNetworkDetails() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final apiService = GetIt.instance<ApiService>();
      final fullNetwork = await apiService.fetchIrcNetworkDetails(widget.network.id);

      if (mounted) {
        setState(() {
          _networkNameController.text = fullNetwork.networkName;
          _hostnameController.text = fullNetwork.hostname;
          _portController.text = fullNetwork.port.toString();
          _serverPasswordController.text = fullNetwork.serverPassword ?? '';
          _nicknameController.text = fullNetwork.nickname;
          _altNicknameController.text = fullNetwork.altNickname ?? '';
          _identController.text = fullNetwork.ident ?? '';
          _realnameController.text = fullNetwork.realname ?? '';
          _quitMessageController.text = fullNetwork.quitMessage ?? '';
          _performCommandsController.text = fullNetwork.performCommands.join('\n');
          _initialChannelsController.text = fullNetwork.initialChannels.join(', ');

          _useSsl = fullNetwork.useSsl;
          _autoReconnect = fullNetwork.autoReconnect;
          _modules = {
            'sasl': fullNetwork.modules.contains('sasl'),
            'nickserv': fullNetwork.modules.contains('nickserv'),
            'keepnick': fullNetwork.modules.contains('keepnick'),
            'kickrejoin': fullNetwork.modules.contains('kickrejoin'),
            'perform': fullNetwork.modules.contains('perform'),
          };
          _isLoading = false;
        });
      }
    } catch (e) {
      print("[EditIrcServerScreen] Error fetching network details: $e");
      if (mounted) {
        setState(() {
          _errorMessage = "Failed to load network details: $e";
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load server details: ${e.toString()}")),
        );
      }
    }
  }

  @override
  void dispose() {
    _networkNameController.dispose();
    _hostnameController.dispose();
    _portController.dispose();
    _serverPasswordController.dispose();
    _nicknameController.dispose();
    _altNicknameController.dispose();
    _identController.dispose();
    _realnameController.dispose();
    _quitMessageController.dispose();
    _performCommandsController.dispose();
    _initialChannelsController.dispose();
    super.dispose();
  }

  void _saveServer() async {
    if (_formKey.currentState?.validate() ?? false) {
      setState(() {
        _isLoading = true;
      });

      // --- START FIX ---
      // Capture the context-dependent objects before the async gap.
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      // --- END FIX ---

      // FIX: Use the directly passed chatController
      final chatController = widget.chatController;

      final List<String> selectedModules =
          _modules.entries.where((e) => e.value).map((e) => e.key).toList();

      String? passwordToSend;
      if (_serverPasswordController.text.isNotEmpty) {
        passwordToSend = _serverPasswordController.text;
      } else if (widget.network.serverPassword != null && widget.network.serverPassword!.isEmpty) {
        passwordToSend = null;
      } else if (widget.network.serverPassword != null && _serverPasswordController.text.isEmpty) {
        passwordToSend = "";
      } else {
        passwordToSend = null;
      }

      final updatedNetwork = IrcNetwork(
        id: widget.network.id,
        networkName: _networkNameController.text.trim(),
        hostname: _hostnameController.text.trim(),
        port: int.parse(_portController.text),
        useSsl: _useSsl,
        serverPassword: passwordToSend,
        autoReconnect: _autoReconnect,
        modules: selectedModules,
        performCommands: _performCommandsController.text.isNotEmpty
            ? _performCommandsController.text.split('\n')
            : [],
        initialChannels: _initialChannelsController.text.isNotEmpty
            ? _initialChannelsController.text
                .split(',')
                .map((e) => e.trim())
                .toList()
            : [],
        nickname: _nicknameController.text.trim(),
        altNickname: _altNicknameController.text.isNotEmpty
            ? _altNicknameController.text.trim()
            : null,
        ident: _identController.text.isNotEmpty
            ? _identController.text.trim()
            : null,
        realname: _realnameController.text.isNotEmpty
            ? _realnameController.text.trim()
            : null,
        quitMessage: _quitMessageController.text.isNotEmpty
            ? _quitMessageController.text.trim()
            : null,
        isConnected: widget.network.isConnected,
        channels: widget.network.channels,
      );

      try {
        await chatController.updateIrcNetwork(updatedNetwork); // Use chatController

        // It's still good practice to check if the widget is mounted.
        if (!mounted) return;

        // Use the captured objects instead of the widget's direct context.
        navigator.pop();
        messenger.showSnackBar(
            SnackBar(
                content: Text(
                    "IRC Network '${updatedNetwork.networkName}' updated successfully!")));
      } catch (e) {
        print("[EditIrcServerScreen] Error updating network: $e");
        if (mounted) {
          // Use the captured messenger here as well.
          messenger.showSnackBar(
            SnackBar(
                content: Text("Failed to update IRC Network: ${e.toString()}")),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.network.networkName}'),
        backgroundColor: const Color(0xFF232428),
      ),
      backgroundColor: const Color(0xFF313338),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTextField(
                          controller: _networkNameController,
                          label: 'Network Name',
                          hint: 'e.g., Libera Chat',
                          validator: (value) =>
                              value?.isEmpty ?? true ? 'Required' : null,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildTextField(
                                controller: _hostnameController,
                                label: 'Hostname',
                                hint: 'irc.example.com',
                                validator: (value) =>
                                    value?.isEmpty ?? true ? 'Required' : null,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 1,
                              child: _buildTextField(
                                controller: _portController,
                                label: 'Port',
                                hint: '6667',
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                validator: (value) {
                                  if (value?.isEmpty ?? true) return 'Required';
                                  final port = int.tryParse(value!);
                                  if (port == null || port < 1 || port > 65535) {
                                    return 'Invalid port';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Checkbox(
                              value: _useSsl,
                              onChanged: (value) => setState(() => _useSsl = value ?? false),
                              fillColor: MaterialStateProperty.resolveWith<Color>((states) {
                                if (states.contains(MaterialState.selected)) {
                                  return const Color(0xFF5865F2);
                                }
                                return Colors.grey;
                              }),
                            ),
                            const Text('Use SSL/TLS', style: TextStyle(color: Colors.white70)),
                            const Spacer(),
                            Checkbox(
                              value: _autoReconnect,
                              onChanged: (value) =>
                                  setState(() => _autoReconnect = value ?? true),
                              fillColor: MaterialStateProperty.resolveWith<Color>((states) {
                                if (states.contains(MaterialState.selected)) {
                                  return const Color(0xFF5865F2);
                                }
                                return Colors.grey;
                              }),
                            ),
                            const Text('Auto-Reconnect',
                                style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _buildTextField(
                          controller: _serverPasswordController,
                          label: 'New Server Password (leave blank to keep current)',
                          obscureText: true,
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Modules',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _modules.keys.map((module) {
                            return FilterChip(
                              label: Text(module),
                              selected: _modules[module] ?? false,
                              onSelected: (selected) =>
                                  setState(() => _modules[module] = selected),
                              selectedColor: const Color(0xFF5865F2),
                              checkmarkColor: Colors.white,
                              labelStyle: TextStyle(
                                color: _modules[module]! ? Colors.white : Colors.white70,
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 24),
                        _buildTextField(
                          controller: _performCommandsController,
                          label: 'Perform Commands (one per line, optional)',
                          hint: 'e.g., /msg nickserv identify password',
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),
                        _buildTextField(
                          controller: _initialChannelsController,
                          label: 'Initial Channels (comma separated, optional)',
                          hint: '#channel1, #channel2',
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Identity Overrides (optional)',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _nicknameController,
                          label: 'Nickname',
                          validator: (value) =>
                              value?.isEmpty ?? true ? 'Required' : null,
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _altNicknameController,
                          label: 'Alternative Nickname',
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _identController,
                          label: 'Ident (Username)',
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _realnameController,
                          label: 'Realname',
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _quitMessageController,
                          label: 'Quit Message',
                        ),
                        const SizedBox(height: 32),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5865F2),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: _isLoading ? null : _saveServer,
                            child: _isLoading
                                ? const CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  )
                                : const Text(
                                    'Update Server',
                                    style: TextStyle(color: Colors.white),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      validator: validator,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: const Color(0xFF232428),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }
}