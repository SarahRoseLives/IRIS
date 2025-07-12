import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart'; // Import GetIt
import '../services/api_service.dart'; // Import ApiService
import '../models/irc_network.dart'; // Import IrcNetwork
import '../controllers/chat_controller.dart'; // Import ChatController

class AddIrcServerScreen extends StatefulWidget {
  const AddIrcServerScreen({super.key});

  @override
  State<AddIrcServerScreen> createState() => _AddIrcServerScreenState();
}

class _AddIrcServerScreenState extends State<AddIrcServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _networkNameController = TextEditingController();
  final TextEditingController _hostnameController = TextEditingController();
  final TextEditingController _portController =
      TextEditingController(text: '6667');
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _altNicknameController = TextEditingController();
  final TextEditingController _identController = TextEditingController();
  final TextEditingController _realnameController = TextEditingController();
  final TextEditingController _quitMessageController = TextEditingController();
  final TextEditingController _performCommandsController =
      TextEditingController();
  final TextEditingController _initialChannelsController =
      TextEditingController();

  bool _useSsl = false;
  bool _autoReconnect = true;
  final Map<String, bool> _modules = {
    'sasl': false,
    'nickserv': false,
    'keepnick': false,
    'kickrejoin': false,
    'perform': false, // This module is more of a client-side flag
  };

  bool _isLoading = false;

  @override
  void dispose() {
    _networkNameController.dispose();
    _hostnameController.dispose();
    _portController.dispose();
    _passwordController.dispose();
    _nicknameController.dispose();
    _altNicknameController.dispose();
    _identController.dispose();
    _realnameController.dispose();
    _quitMessageController.dispose();
    _performCommandsController.dispose();
    _initialChannelsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add IRC Server'),
        backgroundColor: const Color(0xFF232428),
      ),
      backgroundColor: const Color(0xFF313338),
      body: SingleChildScrollView(
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
                controller: _passwordController,
                label: 'Server Password (for SASL or general use, optional)', // Clarified label
                hint: 'Used for SASL if enabled, or direct server password', // Added hint
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
                          'Save Server',
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
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

      // No need to get ApiService directly here, ChatController handles it
      final chatController = GetIt.instance<ChatController>(); // Get ChatController instance

      final List<String> selectedModules =
          _modules.entries.where((e) => e.value).map((e) => e.key).toList();

      final newNetwork = IrcNetwork(
        id: 0, // ID will be assigned by the server
        networkName: _networkNameController.text.trim(),
        hostname: _hostnameController.text.trim(),
        port: int.parse(_portController.text),
        useSsl: _useSsl,
        serverPassword: _passwordController.text.isNotEmpty
            ? _passwordController.text
            : null,
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
        channels: [], // No channels when adding initially
      );

      try {
        await chatController.addIrcNetwork(newNetwork); // Use chatController's method

        // It's still good practice to check if the widget is mounted.
        if (!mounted) return;

        // Use the captured objects instead of the widget's direct context.
        navigator.pop();
        messenger.showSnackBar(
          SnackBar(
              content: Text(
                  "IRC Network '${newNetwork.networkName}' added successfully!"),
          ),
        );
      } catch (e) {
        print("[AddIrcServerScreen] Error saving network: $e");
        if (mounted) {
          // Use the captured messenger here as well.
          messenger.showSnackBar(
            SnackBar(
                content: Text("Failed to add IRC Network: ${e.toString()}")),
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
}