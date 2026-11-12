 import 'dart:async';
 import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'data/kenya_locations.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ------------------------------------------------------------
  // LOCAL EMULATOR CONNECTION (DEBUG ONLY)
  // ------------------------------------------------------------
  //
  // Points Auth, Firestore and Storage at the local Firebase
  // Emulator Suite. This block only runs in debug builds, so
  // release builds continue to use the real project.

             if (kDebugMode) {
    const String host = '127.0.0.1';

    try {
      await FirebaseAuth.instance.useAuthEmulator(host, 9099, automaticHostMapping: false);
      FirebaseFirestore.instance.useFirestoreEmulator(host, 8080, automaticHostMapping: false);
      FirebaseStorage.instance.useStorageEmulator(host, 9199, automaticHostMapping: false); // 👈 MUST BE THIS
      debugPrint('Connected to Firebase emulators via adb reverse at $host');
    } catch (e) {
      debugPrint('Could not connect to emulators: $e');
    }
  }
  await AuthService.initialize();

  runApp(const RentalApp());
}
class AuthService {
   static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  static Future<void> initialize() async {
    await _googleSignIn.initialize(
      serverClientId: '1003821037899-s8obanblc95pinbrjjtu26mmt8j3lgpq.apps.googleusercontent.com',
    );
  }
  static Stream<User?> get authStateChanges =>
      _auth.authStateChanges();

  static User? get currentUser => _auth.currentUser;

  static Future<UserCredential?> signInWithGoogle() async {
    final GoogleSignInAccount googleUser =
        await _googleSignIn.authenticate();

    final GoogleSignInAuthentication googleAuth =
        googleUser.authentication;

    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );

    return await _auth.signInWithCredential(
      credential,
    );
  }

  static Future<UserCredential> signInWithEmail(
    String email,
    String password,
  ) async {
    return await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<UserCredential> registerWithEmail(
    String email,
    String password,
  ) async {
    return await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}
// ============================================================
// AUTHENTICATION SCREEN
// ============================================================

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLogin = true;
  bool isLoading = false;
  bool obscurePassword = true;

  // Tenant, landlord or agent.
String selectedRole = 'tenant';

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // ============================================================
  // EMAIL / PASSWORD
  // ============================================================

  Future<void> _submitEmailPassword() async {
    debugPrint('=== BUTTON PRESSED: STARTING AUTH FLOW ===');
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showMessage(
        'Please enter your email and password.',
      );
      return;
    }

    if (password.length < 6) {
      _showMessage(
        'Password must be at least 6 characters.',
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      if (isLogin) {
        // ==================================================
        // LOGIN
        // ==================================================

        final credential =
            await AuthService.signInWithEmail(
          email,
          password,
        );

        final user = credential.user;

        if (user == null) {
          _showMessage(
            'Could not sign in. Please try again.',
          );
          return;
        }

        await user.reload();

        final refreshedUser =
            FirebaseAuth.instance.currentUser;

        if (refreshedUser == null) {
          _showMessage(
            'Could not load your account.',
          );
          return;
        }

        if (!refreshedUser.emailVerified) {
          await refreshedUser.sendEmailVerification();

          if (!mounted) return;

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const EmailVerificationScreen(),
            ),
          );

          return;
        }

        if (!mounted) return;

        Navigator.pop(context);
      } else {
        // ==================================================
        // CREATE ACCOUNT
        // ==================================================

        final credential =
            await AuthService.registerWithEmail(
          email,
          password,
        );

        final user = credential.user;

        if (user == null) {
          _showMessage(
            'Could not create your account.',
          );
          return;
        }

        // Save the selected role.
        try {
          debugPrint('Attempting to save user to Firestore...');
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .set({
            'uid': user.uid,
            'email': email,
            'role': selectedRole,
            'createdAt': FieldValue.serverTimestamp(),
          });
          debugPrint('Successfully saved user to Firestore!');
        } catch (e) {
          debugPrint('FIRESTORE SAVE ERROR: $e');
          _showMessage('Failed to save profile: $e');
          // We return here so we don't navigate away if it failed
          return; 
        }

        // Send email verification (wrapped in its own try/catch so it doesn't block)
        try {
          await user.sendEmailVerification();
        } catch (e) {
          debugPrint('Email verification error (can be ignored in emulator): $e');
        }

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const EmailVerificationScreen(),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      _showMessage(
        'Firebase error: ${e.code}\n${e.message ?? ''}',
      );
    } catch (e) {
      if (!mounted) return;

      _showMessage(
        'Error: $e',
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // GOOGLE SIGN IN
  // ============================================================

  Future<void> _signInWithGoogle() async {
  setState(() {
    isLoading = true;
  });

  try {
    await AuthService.signInWithGoogle();

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(
        'Could not load your Google account.',
      );
      return;
    }

    // Check whether this Google account already has
    // a RentalApp user profile and role.
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final data = userDoc.data();
    final existingRole = data?['role'];

    // Existing account with a role:
    // allow the user straight into the app.
    if (userDoc.exists &&
        existingRole != null &&
        existingRole.toString().isNotEmpty) {
      if (!mounted) return;

      Navigator.pop(context);
      return;
    }

    if (!mounted) return;

    // New Google user: ask whether they are a
// Tenant, Landlord or Agent.
String selectedGoogleRole = 'tenant';

    final selectedRoleResult =
        await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              title: const Text(
                'How will you use KejaFind?',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Choose your account type to continue.',
                  ),
                  const SizedBox(height: 20),

                  // TENANT
                  InkWell(
                    borderRadius:
                        BorderRadius.circular(16),
                    onTap: () {
                      setDialogState(() {
                        selectedGoogleRole =
                            'tenant';
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color:
                            selectedGoogleRole ==
                                    'tenant'
                                ? primaryOrange
                                    .withOpacity(0.08)
                                : Colors.white,
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                        border: Border.all(
                          color:
                              selectedGoogleRole ==
                                      'tenant'
                                  ? primaryOrange
                                  : Colors
                                      .grey
                                      .shade300,
                          width:
                              selectedGoogleRole ==
                                      'tenant'
                                  ? 2
                                  : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.home_outlined,
                            color:
                                selectedGoogleRole ==
                                        'tenant'
                                    ? primaryOrange
                                    : secondaryTextColor,
                            size: 32,
                          ),
                          const SizedBox(
                            width: 12,
                          ),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                  'Tenant',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'Find a home',
                                  style: TextStyle(
                                    color:
                                        secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selectedGoogleRole ==
                              'tenant')
                            const Icon(
                              Icons.check_circle,
                              color: primaryOrange,
                            ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // LANDLORD
                  InkWell(
                    borderRadius:
                        BorderRadius.circular(16),
                    onTap: () {
                      setDialogState(() {
                        selectedGoogleRole =
                            'landlord';
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color:
                            selectedGoogleRole ==
                                    'landlord'
                                ? primaryOrange
                                    .withOpacity(0.08)
                                : Colors.white,
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                        border: Border.all(
                          color:
                              selectedGoogleRole ==
                                      'landlord'
                                  ? primaryOrange
                                  : Colors
                                      .grey
                                      .shade300,
                          width:
                              selectedGoogleRole ==
                                      'landlord'
                                  ? 2
                                  : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons
                                .home_work_outlined,
                            color:
                                selectedGoogleRole ==
                                        'landlord'
                                    ? primaryOrange
                                    : secondaryTextColor,
                            size: 32,
                          ),
                          const SizedBox(
                            width: 12,
                          ),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                  'Landlord',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'List a property',
                                  style: TextStyle(
                                    color:
                                        secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selectedGoogleRole ==
                              'landlord')
                            const Icon(
                              Icons.check_circle,
                              color: primaryOrange,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // AGENT
                  InkWell(
                    borderRadius:
                        BorderRadius.circular(16),
                    onTap: () {
                      setDialogState(() {
                        selectedGoogleRole =
                            'agent';
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color:
                            selectedGoogleRole ==
                                    'agent'
                                ? primaryOrange
                                    .withOpacity(0.08)
                                : Colors.white,
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                        border: Border.all(
                          color:
                              selectedGoogleRole ==
                                      'agent'
                                  ? primaryOrange
                                  : Colors
                                      .grey
                                      .shade300,
                          width:
                              selectedGoogleRole ==
                                      'agent'
                                  ? 2
                                  : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons
                                .business_center_outlined,
                            color:
                                selectedGoogleRole ==
                                        'agent'
                                    ? primaryOrange
                                    : secondaryTextColor,
                            size: 32,
                          ),
                          const SizedBox(
                            width: 12,
                          ),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                  'Agent',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'Manage properties for owners',
                                  style: TextStyle(
                                    color:
                                        secondaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selectedGoogleRole ==
                              'agent')
                            const Icon(
                              Icons.check_circle,
                              color: primaryOrange,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      null,
                    );
                  },
                  child: const Text(
                    'Cancel',
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      selectedGoogleRole,
                    );
                  },
                  child: const Text(
                    'Continue',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    // User cancelled the role selection.
    if (selectedRoleResult == null) {
      await AuthService.signOut();

      if (mounted) {
        _showMessage(
          'Account setup cancelled.',
        );
      }

      return;
    }

    // Save the Google user's RentalApp profile
    // and selected role.
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({
      'uid': user.uid,
      'email': user.email ?? '',
      'role': selectedRoleResult,
      'createdAt':
          FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;

    Navigator.pop(context);
  } on FirebaseAuthException catch (e) {
    if (!mounted) return;

    _showMessage(
      'Firebase Google error: ${e.code}\n${e.message ?? ''}',
    );
  } catch (e) {
    if (!mounted) return;

    _showMessage(
      'Google error: $e',
    );
  } finally {
    if (mounted) {
      setState(() {
        isLoading = false;
      });
    }
  }
}
  // ============================================================
  // FORGOT PASSWORD
  // ============================================================

  Future<void> _forgotPassword() async {
    final email = emailController.text.trim();

    if (email.isEmpty) {
      _showMessage(
        'Enter your email address first.',
      );
      return;
    }

    try {
      await FirebaseAuth.instance
          .sendPasswordResetEmail(
        email: email,
      );

      if (!mounted) return;

      _showMessage(
        'Password reset email sent.',
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      _showMessage(
        e.message ??
            'Could not send reset email.',
      );
    }
  }

  // ============================================================
  // ROLE CARD
  // ============================================================

  Widget _roleCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
  }) {
    final selected = selectedRole == value;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: isLoading
          ? null
          : () {
              setState(() {
                selectedRole = value;
              });
            },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? primaryOrange.withOpacity(0.08)
              : Colors.white,
          borderRadius:
              BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? primaryOrange
                : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 35,
              color: selected
                  ? primaryOrange
                  : secondaryTextColor,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: selected
                    ? primaryOrange
                    : textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: secondaryTextColor,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isLogin
              ? 'Login'
              : 'Create Account',
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 20),

            // ==================================================
            // HEADER
            // ==================================================

                                     Stack(
              alignment: Alignment.center,
              children: [
                // 1. THE BANNER IMAGE
                Container(
                  width: double.infinity,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    image: const DecorationImage(
                      image: AssetImage('assets/icons/login_banner.png'),
                      fit: BoxFit.fitWidth,
                    ),
                  ),
                ),

                // 2. THE TEXT (Overlay)
                Positioned(
                  top: 50, // Adjust this to move the text up/down
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'KejaFind',
                        style: TextStyle(
                          color: Color(0xFF29231F), 
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Find your next home',
                        style: TextStyle(
                          color: Color(0xFF75675C), 
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 30),

            Text(
              isLogin
                  ? 'Welcome back'
                  : 'Create your account',
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              isLogin
                  ? 'Login to continue using your KejaFind account.'
                  : 'Create an account to save homes, manage listings and more.',
              style: const TextStyle(
                color: secondaryTextColor,
              ),
            ),

            const SizedBox(height: 25),

            // ==================================================
// TENANT / LANDLORD / AGENT SELECTION
// ==================================================

if (!isLogin) ...[
  const Text(
    'How will you use KejaFind?',
    style: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.bold,
    ),
  ),

  const SizedBox(height: 10),

  _roleCard(
    icon: Icons.home_outlined,
    title: 'Tenant',
    subtitle: 'Find a home',
    value: 'tenant',
  ),

  const SizedBox(height: 12),

  _roleCard(
    icon: Icons.home_work_outlined,
    title: 'Landlord',
    subtitle: 'List and manage your own properties',
    value: 'landlord',
  ),

  const SizedBox(height: 12),

  _roleCard(
    icon: Icons.business_center_outlined,
    title: 'Agent',
    subtitle: 'Manage properties for owners',
    value: 'agent',
  ),

  const SizedBox(height: 25),
],
            // ==================================================
            // EMAIL
            // ==================================================

            TextField(
              controller: emailController,
              keyboardType:
                  TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon:
                    Icon(Icons.email_outlined),
                border:
                    OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 15),

            // ==================================================
            // PASSWORD
            // ==================================================

            TextField(
              controller: passwordController,
              obscureText: obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon:
                    const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      obscurePassword =
                          !obscurePassword;
                    });
                  },
                  icon: Icon(
                    obscurePassword
                        ? Icons
                            .visibility_outlined
                        : Icons
                            .visibility_off_outlined,
                  ),
                ),
                border:
                    const OutlineInputBorder(),
              ),
            ),

            // ==================================================
            // FORGOT PASSWORD
            // ==================================================

            if (isLogin)
              Align(
                alignment:
                    Alignment.centerRight,
                child: TextButton(
                  onPressed: isLoading
                      ? null
                      : _forgotPassword,
                  child: const Text(
                    'Forgot password?',
                  ),
                ),
              ),

            const SizedBox(height: 10),

            // ==================================================
            // EMAIL BUTTON
            // ==================================================

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: isLoading
                    ? null
                    : _submitEmailPassword,
                child: isLoading
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        isLogin
                            ? 'Login'
                            : 'Create Account',
                      ),
              ),
            ),

            const SizedBox(height: 20),

            // ==================================================
            // OR
            // ==================================================

            Row(
              children: [
                Expanded(
                  child: Divider(
                    color:
                        Colors.grey.shade300,
                  ),
                ),
                const Padding(
                  padding:
                      EdgeInsets.symmetric(
                    horizontal: 12,
                  ),
                  child: Text(
                    'OR',
                    style: TextStyle(
                      color:
                          secondaryTextColor,
                    ),
                  ),
                ),
                Expanded(
                  child: Divider(
                    color:
                        Colors.grey.shade300,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ==================================================
            // GOOGLE
            // ==================================================

                        SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: isLoading
                    ? null
                    : _signInWithGoogle,
                icon: Image.asset(
                  'assets/icons/google_logo.png', // <-- YOUR NEW LOGO
                  height: 24, // Keeps it scaled nicely with the text
                  width: 24,
                ),
                label: const Text(
                  'Continue with Google',
                ),
              ),
            ),
            const SizedBox(height: 25),

            // ==================================================
            // LOGIN / CREATE TOGGLE
            // ==================================================

            Center(
              child: TextButton(
                onPressed: isLoading
                    ? null
                    : () {
                        setState(() {
                          isLogin = !isLogin;
                        });
                      },
                child: Text(
                  isLogin
                      ? 'Create a new account'
                      : 'Already have an account? Login',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// PROFILE SCREEN
// ============================================================

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<void> _editPhoneNumber(
  BuildContext context,
  User user,
  String currentPhone,
) async {
  final controller = TextEditingController(
    text: currentPhone,
  );

  final phone = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      String? errorText;

      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Phone Number'),
            content: TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Kenyan phone number',
                hintText: '0713724918 or +254713724918',
                prefixIcon: const Icon(Icons.phone),
                errorText: errorText,
              ),
              onChanged: (_) {
                if (errorText != null) {
                  setDialogState(() {
                    errorText = null;
                  });
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final enteredPhone =
                      controller.text.trim();

                  // Remove spaces and hyphens.
                  final cleanedPhone =
                      enteredPhone
                          .replaceAll(' ', '')
                          .replaceAll('-', '');

                  String normalizedPhone;

                  // Local Kenyan format:
                  // 0713724918 or 0113724918
                  if (RegExp(
                    r'^(07|01)\d{8}$',
                  ).hasMatch(cleanedPhone)) {
                    normalizedPhone =
                        '+254${cleanedPhone.substring(1)}';
                  }

                  // International Kenyan format:
                  // +254713724918 or +254113724918
                  else if (RegExp(
                    r'^\+254(7|1)\d{8}$',
                  ).hasMatch(cleanedPhone)) {
                    normalizedPhone = cleanedPhone;
                  }

                  // Invalid number.
                  else {
                    setDialogState(() {
                      errorText =
                          'Enter a valid Kenyan mobile number';
                    });
                    return;
                  }

                  Navigator.of(dialogContext).pop(
                    normalizedPhone,
                  );
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );

  if (phone == null || phone.isEmpty) {
    controller.dispose();
    return;
  }

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(
      {
        'phone': phone,
      },
      SetOptions(merge: true),
    );

    if (!mounted) {
      controller.dispose();
      return;
    }

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Phone number saved'),
      ),
    );
  } catch (e) {
    if (!mounted) {
      controller.dispose();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not save phone number: $e',
        ),
      ),
    );
  }

  controller.dispose();
}
     Future<void> _deleteAccount(BuildContext context, User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 50),
          title: const Text('Delete Account?'),
          content: const Text(
            'This will permanently delete your account and remove your data. This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete Permanently', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final firestore = FirebaseFirestore.instance;

      // 1. Delete Firestore Data FIRST (while the user is still authenticated)
      await firestore.collection('users').doc(user.uid).delete();

      final properties = await firestore.collection('properties').where('ownerId', isEqualTo: user.uid).get();
      for (var doc in properties.docs) { await doc.reference.delete(); }

      final managedProperties = await firestore.collection('properties').where('managedById', isEqualTo: user.uid).get();
      for (var doc in managedProperties.docs) { await doc.reference.delete(); }

      final viewings = await firestore.collection('viewing_requests').where('tenantId', isEqualTo: user.uid).get();
      for (var doc in viewings.docs) { await doc.reference.delete(); }

      // 2. Delete Auth Account LAST
      await user.delete();

      if (!context.mounted) return;
      Navigator.pop(context); // Close loading

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deleted successfully.')),
      );

    } on FirebaseAuthException catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // Close loading

      if (e.code == 'requires-recent-login') {
        // If Firebase requires a fresh login, we must sign out and force re-login
        await FirebaseAuth.instance.signOut();
        
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('For security, please log back in to delete your account.'),
            duration: Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete account: ${e.message}')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // Close loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
      ),
      body: StreamBuilder<User?>(
        stream: AuthService.authStateChanges,
        builder: (context, snapshot) {
          final user = snapshot.data;

          if (user == null) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildProfileHeader(null),
                const SizedBox(height: 20),
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: primaryOrange,
                      child: Icon(
                        Icons.login,
                        color: Colors.white,
                      ),
                    ),
                    title: const Text(
                      'Login / Create Account',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: const Text(
                      'Save homes, manage viewings and more',
                    ),
                    trailing: const Icon(
                      Icons.arrow_forward_ios,
                      size: 18,
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AuthScreen(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),

                _buildAboutCard(context),
              ],
            );
          }

          return FutureBuilder<
              DocumentSnapshot<Map<String, dynamic>>>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .get(),
            builder: (context, roleSnapshot) {
              String role = 'tenant';

              if (roleSnapshot.hasData &&
                  roleSnapshot.data!.exists) {
                final data = roleSnapshot.data!.data();
                final savedRole = data?['role'];

                if (savedRole == 'landlord' ||
                    savedRole == 'tenant' ||
                    savedRole == 'agent' ||
                    savedRole == 'admin') {
                  role = savedRole as String;
                }
              }

              final isLandlord = role == 'landlord';
              final isAgent = role == 'agent';
              final isAdmin = role == 'admin';

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildProfileHeader(user),
                  const SizedBox(height: 20),

                  // ACCOUNT
                  Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: availableGreen,
                        child: Icon(
                          Icons.verified_user,
                          color: Colors.white,
                        ),
                      ),
                      title: const Text(
                        'Account signed in',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        user.email ?? 'KejaFind account',
                      ),
                      trailing: TextButton(
                        onPressed: () async {
                          await AuthService.signOut();
                        },
                        child: const Text('Sign Out'),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ACCOUNT TYPE
                  Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: primaryOrange,
                        child: Icon(
                          isAdmin
                              ? Icons.admin_panel_settings
                              : isLandlord
                                  ? Icons.home_work
                                  : isAgent
                                      ? Icons.business
                                      : Icons.person,
                          color: Colors.white,
                        ),
                      ),
                      title: Text(
                        isAdmin
                            ? 'Admin Account'
                            : isLandlord
                                ? 'Landlord Account'
                                : isAgent
                                    ? 'Agent Account'
                                    : 'Tenant Account',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        isAdmin
                            ? 'Manage and verify KejaFind activities'
                            : isLandlord
                                ? 'Manage and rent out your properties'
                                : isAgent
                                    ? 'Manage properties for owners'
                                    : 'Find homes and manage your viewings',
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // CONTACT DETAILS
                  Card(
                    child: FutureBuilder<
                        DocumentSnapshot<Map<String, dynamic>>>(
                      future: FirebaseFirestore.instance
                          .collection('users')
                          .doc(user.uid)
                          .get(),
                      builder: (context, phoneSnapshot) {
                        String phone = '';

                        if (phoneSnapshot.hasData &&
                            phoneSnapshot.data!.exists) {
                          final data =
                              phoneSnapshot.data!.data();
                          phone =
                              data?['phone']?.toString() ?? '';
                        }

                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: primaryOrange,
                            child: Icon(
                              Icons.phone,
                              color: Colors.white,
                            ),
                          ),
                          title: const Text(
                            'Phone Number',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            phone.isEmpty
                                ? 'Add your phone number'
                                : phone,
                          ),
                          trailing: const Icon(
                            Icons.edit_outlined,
                            size: 20,
                          ),
                          onTap: () {
                            _editPhoneNumber(
                              context,
                              user,
                              phone,
                            );
                          },
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 12),

                  // SAVED HOMES
                  if (!isAdmin) ...[
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.favorite,
                          color: primaryOrange,
                        ),
                        title: const Text(
                          'Saved Homes',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'View homes you saved',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SavedScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),

                    // VIEWING REQUESTS
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.calendar_month,
                          color: primaryOrange,
                        ),
                        title: const Text(
                          'My Viewings',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Manage your property viewings',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ViewingsScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // LANDLORD AND AGENT OPTIONS
                  if (isLandlord || isAgent) ...[
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: primaryOrange,
                          child: Icon(
                            Icons.home_work_outlined,
                            color: Colors.white,
                          ),
                        ),
                        title: const Text(
                          'My Listings',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'View and manage your properties',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const MyListingsScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: primaryOrange,
                          child: Icon(
                            Icons.add_home_work_outlined,
                            color: Colors.white,
                          ),
                        ),
                        title: const Text(
                          'List Your Property',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Rent out your property on KejaFind',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const LandlordDashboardScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  // ADMIN OPTIONS
                  if (isAdmin) ...[
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: darkOrange,
                          child: Icon(
                            Icons.admin_panel_settings_outlined,
                            color: Colors.white,
                          ),
                        ),
                        title: const Text(
                          'Admin Dashboard',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Review and manage property listings',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const AdminDashboardScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: primaryOrange,
                          child: Icon(
                            Icons.verified_outlined,
                            color: Colors.white,
                          ),
                        ),
                        title: const Text(
                          'Agent Verification',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Review agent representation requests',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios,
                          size: 18,
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const AdminAgentVerificationScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  const SizedBox(height: 8),
                  _buildAboutCard(context),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildProfileHeader(User? user) {
    final isSignedIn = user != null;

        return Container(
      padding: const EdgeInsets.all(0), // Padding moved to inner container
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        image: const DecorationImage(
          image: AssetImage('assets/icons/splash_background.png'),
          fit: BoxFit.cover,
        ),
      ),
      // Inner container for the dark overlay so white text is readable
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Colors.black.withOpacity(0.4), 
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: Colors.white,
              backgroundImage: user?.photoURL != null
                  ? NetworkImage(user!.photoURL!)
                  : null,
              child: user?.photoURL == null
                  ? const Icon(
                      Icons.person,
                      color: primaryOrange,
                      size: 35,
                    )
                  : null,
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.displayName ?? 'KejaFind User',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isSignedIn
                        ? (user.email ?? 'Account signed in')
                        : 'Tenant account',
                    style: const TextStyle(
                      color: Colors.white70,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
   Widget _buildAboutCard(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Card(
      child: ListTile(
        leading: const Icon(
          Icons.info_outline,
          color: primaryOrange,
        ),
        title: const Text(
          'About KejaFind',
        ),
        trailing: const Icon(
          Icons.arrow_forward_ios,
          size: 18,
        ),
        onTap: () {
          showDialog(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('About KejaFind'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'KejaFind helps tenants discover available homes online instead of walking around looking for houses.',
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Version 1.0.0',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '© 2026 Justus Arisi. All rights reserved.',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                    const Divider(height: 30),
                    
                    // THE DANGER ZONE
                    if (user != null)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(dialogContext); // Close this dialog
                          _deleteAccount(context, user); // Trigger delete
                        },
                        icon: const Icon(Icons.delete_forever, color: Colors.red),
                        label: const Text(
                          'Delete My Account',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
} // <--- THIS BRACE CLOSES THE CLASS. Make sure it is there!

// ============================================================
// EMAIL VERIFICATION SCREEN
// ============================================================

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState
    extends State<EmailVerificationScreen> {
  bool isChecking = false;
  bool isSending = false;

  // ============================================================
  // CHECK VERIFICATION
  // ============================================================

  Future<void> _checkVerification() async {
    setState(() {
      isChecking = true;
    });

    try {
      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (!mounted) return;

        Navigator.pop(context);
        return;
      }

      await user.reload();

      final refreshedUser =
          FirebaseAuth.instance.currentUser;

      if (refreshedUser != null &&
          refreshedUser.emailVerified) {
        if (!mounted) return;

        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Email verified successfully!',
            ),
          ),
        );

        Navigator.pop(context);
      } else {
        if (!mounted) return;

        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Your email is not verified yet. Please check your inbox.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Could not check verification status.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isChecking = false;
        });
      }
    }
  }

  // ============================================================
  // RESEND VERIFICATION EMAIL
  // ============================================================

  Future<void> _resendVerificationEmail() async {
    setState(() {
      isSending = true;
    });

    try {
      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) {
        return;
      }

      await user.sendEmailVerification();

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Verification email sent again.',
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;

      String message =
          'Could not send verification email.';

      if (e.code == 'too-many-requests') {
        message =
            'Please wait before requesting another email.';
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Could not send verification email.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  // ============================================================
  // SIGN OUT
  // ============================================================

  Future<void> _signOut() async {
    await AuthService.signOut();

    if (!mounted) return;

    Navigator.pop(context);
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final user =
        FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Verify Your Email',
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 35),

            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    primaryOrange,
                    darkOrange,
                  ],
                ),
                borderRadius:
                    BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.mark_email_unread_outlined,
                color: Colors.white,
                size: 75,
              ),
            ),

            const SizedBox(height: 30),

            const Text(
              'Check your email',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            const Text(
              'We sent a verification link to your email address.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: 16,
              ),
            ),

            const SizedBox(height: 15),

            if (user?.email != null)
              Text(
                user!.email!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),

            const SizedBox(height: 25),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    primaryOrange.withOpacity(0.08),
                borderRadius:
                    BorderRadius.circular(15),
              ),
              child: const Text(
                'Open your email and tap the verification link. Then return here and tap “I’ve Verified My Email”.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                ),
              ),
            ),

            const SizedBox(height: 25),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: isChecking
                    ? null
                    : _checkVerification,
                icon: isChecking
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.verified_outlined,
                      ),
                label: Text(
                  isChecking
                      ? 'Checking...'
                      : 'I’ve Verified My Email',
                ),
              ),
            ),

            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton.icon(
                onPressed: isSending
                    ? null
                    : _resendVerificationEmail,
                icon: const Icon(
                  Icons.email_outlined,
                ),
                label: Text(
                  isSending
                      ? 'Sending...'
                      : 'Resend Verification Email',
                ),
              ),
            ),

            const SizedBox(height: 25),

            TextButton(
              onPressed: _signOut,
              child: const Text(
                'Use a different account',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// ============================================================
// APP
// ============================================================
class KejaFindSplashScreen extends StatefulWidget {
  const KejaFindSplashScreen({super.key});

  @override
  State<KejaFindSplashScreen> createState() =>
      _KejaFindSplashScreenState();
}

class _KejaFindSplashScreenState
    extends State<KejaFindSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fade = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );

    _scale = Tween<double>(
      begin: 0.88,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ),
    );

    _controller.forward();

    // Welcome briefly, then open the existing Home screen.
    Future.delayed(
      const Duration(seconds: 8),
      () {
        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => const MainNavigationScreen(),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _roleIcon(IconData icon, String title, String subtitle) {
  return Expanded(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFFF3DFC9),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            icon,
            color: primaryOrange,
            size: 26,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Color(0xFF29231F),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: Color(0xFF75675C),
            height: 1.35,
          ),
        ),
      ],
    ),
  );
}

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Removed the solid background color
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/icons/splash_background.png'),
            fit: BoxFit.cover, // Makes the image fill the whole screen
          ),
        ),
        child: SafeArea(
          child: Center(
            child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                                       // 1. The Logo (No background container, just the image)
                                        // THE NEW LOGO CONTAINER
                    Container(
                      width: 130,
                      height: 130,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white, // White box so the orange logo pops
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [
                          BoxShadow(
                            color: primaryOrange.withOpacity(0.25),
                            blurRadius: 24,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Image.asset(
                        'assets/icons/logo_transparent.png', // Ensure you have this file
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // 2. The App Name
                    const Text(
                      'KejaFind',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                        color: Color(0xFF29231F),
                      ),
                    ),

                    const SizedBox(height: 10),

                    // 3. The Tagline
                    const Text(
                      'Find a place to call home.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        color: Color(0xFF75675C),
                      ),
                    ),
                    const SizedBox(height: 42),

                    const Text(
                      'YOUR NEXT CHAPTER STARTS HERE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                        color: Color(0xFF9B7655),
                      ),
                    ),

                    const SizedBox(height: 20),

                                                            Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _roleIcon(
                          Icons.search_rounded,
                          'Tenant',
                          'Find a Home',
                        ),
                        _roleIcon(
                          Icons.home_work_outlined,
                          'Landlord',
                          'List a Home',
                        ),
                        _roleIcon(
                          Icons.handshake_outlined,
                          'Agent',
                          'Manage Homes',
                        ),
                      ],
                    ),
                    const SizedBox(height: 48),

                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: primaryOrange,
                      ),
                    ),

                    const SizedBox(height: 14),

                    const Text(
                      'Making your next move easier',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF897D72),
                      ),
                    ),
                  ],
                                ), // Closes the Column
              ), // Closes the Padding
            ), // Closes the ScaleTransition
          ), // Closes the FadeTransition
        ), // Closes the Center
      ), // Closes the SafeArea
    ), // Closes the Container (The background image)
  ); // Closes the Scaffold
 }
}
class RentalApp extends StatelessWidget {
  const RentalApp({super.key});

  @override
  Widget build(BuildContext context) {
          return MaterialApp(
      title: 'KejaFind',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF57C00),
        ),
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF212121),
          elevation: 0,
        ),
      ),
      home: const KejaFindSplashScreen(),
    );
  }
}

// ============================================================
// COLORS
// ============================================================

const Color primaryOrange = Color(0xFFF57C00);
const Color darkOrange = Color(0xFFE65100);
const Color backgroundColor = Color(0xFFFAFAFA);
const Color textColor = Color(0xFF212121);
const Color secondaryTextColor = Color(0xFF757575);
const Color availableGreen = Color(0xFF2E7D32);

// ============================================================
// PROPERTY MODEL
// ============================================================

class RentalProperty {
  final String id;
final String ownerId;
final String managedById;
final String managedByType;
final String ownerName;
final String ownerPhone;
final String ownerEmail;
final String title;
final String location;
  final String propertyType;
  final String propertySetting;
  final int rent;
  final int bedrooms;
  final int bathrooms;
  final int size;
  final String availability;
  final DateTime? availableFrom;
  final String description;
  final List<String> amenities;
  final List<String> photoPaths;

  const RentalProperty({
  required this.id,
  required this.ownerId,
required this.managedById,
required this.managedByType,
required this.ownerName,
required this.ownerPhone,
required this.ownerEmail,
required this.title,
  required this.location,
    required this.propertyType,
    this.propertySetting = '',
    required this.rent,
    required this.bedrooms,
    required this.bathrooms,
    required this.size,
    this.availability = 'Available now',
    this.availableFrom,
    
    required this.description,
    required this.amenities,
    required this.photoPaths,
  });
}
// ============================================================
// MOCK PROPERTIES
// ============================================================

const List<RentalProperty> rentalProperties = [
  RentalProperty(
    id: 'property_1',
        ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Modern Bedsitter',
    location: 'Kileleshwa, Nairobi',
    propertyType: 'Bedsitter / Studio',
    rent: 22000,
    bedrooms: 0,
    bathrooms: 1,
    size: 450,
    description:
        'A modern and comfortable bedsitter in a convenient Kileleshwa location.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Internet',
      'CCTV',
    ],
    photoPaths: [],
  ),
  RentalProperty(
    id: 'property_2',
    ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Executive 1 Bedroom Apartment',
    location: 'Kilimani, Nairobi',
    propertyType: 'Apartment',
    rent: 32000,
    bedrooms: 1,
    bathrooms: 1,
    size: 750,
    description:
        'Beautiful one bedroom apartment in a popular Kilimani residential area.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Lift',
      'Internet',
    ],
    photoPaths: [],
  ),
  RentalProperty(
    id: 'property_3',
    ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Modern 2 Bedroom Apartment',
    location: 'Kileleshwa, Nairobi',
    propertyType: 'Apartment',
    rent: 45000,
    bedrooms: 2,
    bathrooms: 2,
    size: 1100,
    description:
        'Spacious two bedroom apartment suitable for a family or professionals.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Lift',
      'Generator',
    ],
    photoPaths: [],
  ),
  RentalProperty(
    id: 'property_4',
    ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Spacious 3 Bedroom Home',
    location: 'Lavington, Nairobi',
    propertyType: 'Standalone House',
    rent: 68000,
    bedrooms: 3,
    bathrooms: 2,
    size: 1450,
    description:
        'Large three bedroom home in a quiet and secure Lavington neighborhood.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Internet',
      'Balcony',
    ],
    photoPaths: [],
  ),
  RentalProperty(
    id: 'property_5',
    ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Affordable 1 Bedroom',
    location: 'Nairobi West, Nairobi',
    propertyType: 'Apartment',
    rent: 28000,
    bedrooms: 1,
    bathrooms: 1,
    size: 700,
    description:
        'Affordable one bedroom apartment with easy access to major Nairobi routes.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Internet',
    ],
    photoPaths: [],
  ),
  RentalProperty(
    id: 'property_6',
    ownerId: '',
    managedById: '',
    managedByType: '',
    ownerName: '',
    ownerPhone: '',
    ownerEmail: '',
    title: 'Premium 3 Bedroom Apartment',
    location: 'Kilimani, Nairobi',
    propertyType: 'Apartment',
    rent: 85000,
    bedrooms: 3,
    bathrooms: 3,
    size: 1650,
    description:
        'Premium three bedroom apartment with modern finishes and excellent amenities.',
    amenities: [
      'Parking',
      'Security',
      'Water',
      'Lift',
      'Swimming Pool',
      'Generator',
      'CCTV',
    ],
    photoPaths: [],
  ),
];

// ============================================================
// SAVED PROPERTIES
// ============================================================

class SavedProperties {
  static final ValueNotifier<Set<String>> savedIds =
      ValueNotifier<Set<String>>({});

  static void toggle(String id) {
    final updated = Set<String>.from(savedIds.value);

    if (updated.contains(id)) {
      updated.remove(id);
    } else {
      updated.add(id);
    }

    savedIds.value = updated;
  }

  static bool isSaved(String id) {
    return savedIds.value.contains(id);
  }
}

// ============================================================
// VIEWING REQUEST MODEL
// ============================================================

class ViewingRequest {
  final RentalProperty property;
  final String name;
  final String phone;
  final DateTime date;
  final String time;
  final String message;

  ViewingRequest({
    required this.property,
    required this.name,
    required this.phone,
    required this.date,
    required this.time,
    required this.message,
  });
}

class ViewingRequests {
  static final ValueNotifier<List<ViewingRequest>> requests =
      ValueNotifier<List<ViewingRequest>>([]);

  static void add(ViewingRequest request) {
    requests.value = [
      ...requests.value,
      request,
    ];
  }
}

// ============================================================
// LANDLORD LISTING MODEL
// ============================================================

// ============================================================
// AGENT → OWNER REPRESENTATION REQUEST
// ============================================================

class OwnerRepresentationRequest {
  final String id;
  final String propertyId;
  final String agentId;
  final String ownerName;
  final String ownerPhone;
  final String ownerEmail;
  final String status;
  final DateTime createdAt;

  OwnerRepresentationRequest({
    required this.id,
    required this.propertyId,
    required this.agentId,
    required this.ownerName,
    required this.ownerPhone,
    required this.ownerEmail,
    required this.status,
    required this.createdAt,
  });
}
class LandlordListing {
  final String id;
  final String ownerId;
  final String managedById;
  final String title;
  final String location;
  final String propertyType;
  final String propertySetting;
  final int rent;
  final int bedrooms;
  final int bathrooms;
  final int size;
  final String availability;
  final DateTime? availableFrom;
  final String description;
  final List<String> amenities;
  final DateTime submittedAt;
  final List<String> photoPaths;

  LandlordListing({
    required this.id,
    required this.ownerId,
    required this.managedById,
    required this.title,
    required this.location,
    required this.propertyType,
    this.propertySetting = 'Apartment Block',
    required this.rent,
    required this.bedrooms,
    required this.bathrooms,
    required this.size,
    required this.availability,
    this.availableFrom,
    required this.description,
    required this.amenities,
    required this.submittedAt,
    required this.photoPaths,
  });
}
class LandlordListings {
  static final ValueNotifier<List<LandlordListing>> listings =
      ValueNotifier<List<LandlordListing>>([]);

  static void add(LandlordListing listing) {
    listings.value = [
      ...listings.value,
      listing,
    ];
  }
}

RentalProperty rentalPropertyFromFirestore(
  Map<String, dynamic> data,
) {
  return RentalProperty(
  id: data['id']?.toString() ?? '',
  ownerId: data['ownerId']?.toString() ?? '',
  managedById: data['managedById']?.toString() ?? '',
  managedByType: data['managedByType']?.toString() ?? '',
  ownerName: data['ownerName']?.toString() ?? '',
  ownerPhone: data['ownerPhone']?.toString() ?? '',
  ownerEmail: data['ownerEmail']?.toString() ?? '',
  title: data['title']?.toString() ?? 'Untitled Property',
    location: data['location']?.toString() ?? '',
    propertyType:
        data['propertyType']?.toString() ?? 'Apartment',
        propertySetting: data['propertySetting']?.toString() ?? '',
    rent: (data['rent'] as num?)?.toInt() ?? 0,
    bedrooms: (data['bedrooms'] as num?)?.toInt() ?? 0,
    bathrooms: (data['bathrooms'] as num?)?.toInt() ?? 0,
    size: (data['size'] as num?)?.toInt() ?? 0,

    // Availability from Firestore.
    availability:
        data['availability']?.toString() ?? 'Available now',
        availableFrom: data['availableFrom'] is Timestamp
    ? (data['availableFrom'] as Timestamp).toDate()
    : null,

    description:
        data['description']?.toString() ?? '',
    amenities: List<String>.from(
      data['amenities'] ?? [],
    ),
    photoPaths: List<String>.from(
      data['photoPaths'] ?? [],
    ),
  );
}

// ============================================================
// HOME SCREEN
// ============================================================
class FirestoreRentalProperties extends StatelessWidget {
  final String? selectedCounty;
  final String? selectedCity;
  final String? selectedArea;
  

  const FirestoreRentalProperties({
    super.key,
    this.selectedCounty,
    this.selectedCity,
    this.selectedArea,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
      .collection('properties')
      .where('status', isEqualTo: 'approved')
      .where('verified', isEqualTo: true)
      .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Could not load rental homes.',
              textAlign: TextAlign.center,
            ),
          );
        }

        final documents = snapshot.data?.docs ?? [];

        if (documents.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text(
                'No landlord listings available yet.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final filteredDocuments = documents.where((doc) {
          final data = doc.data();
            final availability =
                data['availability']?.toString() ?? 'Available now';

            if (availability == 'Rented / Occupied') {
              return false;
            }
          final county =
              data['county']?.toString() ?? '';
          final city =
              data['city']?.toString() ?? '';
          final area =
              data['area']?.toString() ?? '';

          if (selectedCounty != null &&
              county != selectedCounty) {
            return false;
          }

          if (selectedCity != null &&
              city != selectedCity) {
            return false;
          }

          if (selectedArea != null &&
              area != selectedArea) {
            return false;
          }

          return true;
        }).toList();

        if (filteredDocuments.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text(
                'No rental homes found in this location yet.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final properties = filteredDocuments
            .map(
              (doc) => rentalPropertyFromFirestore(
                doc.data(),
              ),
            )
            .toList();

        return Column(
          children: properties
              .map(
                (property) => PropertyCard(
                  property: property,
                ),
              )
              .toList(),
        );
      },
    );
  }
}

// ============================================================
// HOME SCREEN
// ============================================================

class HomeScreen extends StatefulWidget {
  final VoidCallback? onProfileTap;
  
  const HomeScreen({super.key, this.onProfileTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController searchController =
      TextEditingController();

  String selectedBedroomFilter = 'Any';
  String selectedPropertyTypeFilter = 'Any';

  String? selectedCounty;
  String? selectedCity;
  String? selectedArea;
  String selectedBathroomFilter = 'Any';

int? selectedMinRent;
int? selectedMaxRent;

String selectedAvailabilityFilter = 'Any';

List<String> selectedAmenities = [];

  void openArea(String area) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SearchResultsScreen(
  query: area,
  bedroomFilter: 'Any',
  bathroomFilter: 'Any',
  propertyTypeFilter: 'Any',
  title: '$area Rentals',
),
    ),
  );
}

@override
Widget build(BuildContext context) {
  return Scaffold(
    backgroundColor: backgroundColor,
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'KejaFind',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'Find your next home',
            style: TextStyle(
              fontSize: 12,
              color: secondaryTextColor,
            ),
          ),
        ],
      ),
            actions: [
        IconButton(
          onPressed: () {
            // This triggers the callback passed from MainNavigationScreen
            widget.onProfileTap?.call(); 
          },
          icon: const Icon(Icons.person_outline),
        ),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHero(),
            _buildLocationSelector(),
            _buildFilters(),
            _buildPopularAreas(),
            _buildNewHomes(),
          ],
        ),
      ),
    ),
  );
}

Widget _buildHero() {
  return Container(
    margin: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      image: const DecorationImage(
        image: AssetImage('assets/icons/splash_background.png'),
        fit: BoxFit.cover,
      ),
    ),
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.4),
            Colors.black.withOpacity(0.7),
          ],
        ),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Find a home you’ll love.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Search real rental homes by location, price and bedrooms.',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => performSearch(),
            decoration: InputDecoration(
              hintText: 'Search area, bedroom or property',
              filled: true,
              fillColor: Colors.white,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: performSearch,
                icon: const Icon(
                  Icons.arrow_forward,
                  color: darkOrange,
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
Widget _buildLocationSelector() {
  return Container(
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: primaryOrange.withOpacity(0.18),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: primaryOrange.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on_rounded,
                color: primaryOrange,
              ),
            ),

            const SizedBox(width: 12),

            const Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    'Where are you looking?',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Choose a location to find homes',
                    style: TextStyle(
                      fontSize: 13,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        _buildLocationOption(
          icon: Icons.map_outlined,
          title: 'County',
          value:
              selectedCounty ?? 'Select county',
          enabled: true,
          onTap: () {
            _showLocationPicker(
              title: 'Select County',
              items: tenantCountyOptions,
              selectedValue: selectedCounty,
              onSelected: (value) {
                setState(() {
                  selectedCounty = value;
                  selectedCity = null;
                  selectedArea = null;
                });
              },
            );
          },
        ),

        const SizedBox(height: 8),

        _buildLocationOption(
          icon: Icons.location_city_outlined,
          title: 'City / Town',
          value:
              selectedCity ?? 'Select city or town',
          enabled: selectedCounty != null,
          onTap: selectedCounty == null
              ? null
              : () {
                  _showLocationPicker(
                    title: 'Select City / Town',
                    items: tenantCityOptions,
                    selectedValue: selectedCity,
                    onSelected: (value) {
                      setState(() {
                        selectedCity = value;
                        selectedArea = null;
                      });
                    },
                  );
                },
        ),

        const SizedBox(height: 8),

        _buildLocationOption(
          icon: Icons.place_outlined,
          title: 'Area / Estate',
          value:
              selectedArea ?? 'Select area or estate',
          enabled: selectedCity != null,
          onTap: selectedCity == null
              ? null
              : () {
                  _showLocationPicker(
                    title: 'Select Area / Estate',
                    items: tenantAreaOptions,
                    selectedValue: selectedArea,
                    onSelected: (value) {
                      setState(() {
                        selectedArea = value;
                      });
                    },
                  );
                },
        ),

        if (selectedCounty != null ||
            selectedCity != null ||
            selectedArea != null) ...[
          const SizedBox(height: 12),

          Row(
            children: [
              const Icon(
                Icons.check_circle,
                size: 17,
                color: availableGreen,
              ),

              const SizedBox(width: 7),

              Expanded(
                child: Text(
                  [
                    if (selectedCounty != null)
                      selectedCounty!,
                    if (selectedCity != null)
                      selectedCity!,
                    if (selectedArea != null)
                      selectedArea!,
                  ].join(' • '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: availableGreen,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              TextButton(
                onPressed: () {
                  setState(() {
                    selectedCounty = null;
                    selectedCity = null;
                    selectedArea = null;
                  });
                },
                child: const Text(
                  'Clear',
                  style: TextStyle(
                    color: primaryOrange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
Widget _buildLocationOption({
  required IconData icon,
  required String title,
  required String value,
  required bool enabled,
  required VoidCallback? onTap,
}) {
  final bool hasValue =
      value != 'Select county' &&
      value != 'Select city or town' &&
      value != 'Select area or estate';

  return Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFFFFF8F2)
              : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: enabled
                ? primaryOrange.withOpacity(0.12)
                : Colors.grey.withOpacity(0.12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: enabled
                  ? primaryOrange
                  : Colors.grey,
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      color: enabled
                          ? secondaryTextColor
                          : Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 2),

                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: hasValue
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: enabled
                          ? (hasValue
                              ? textColor
                              : secondaryTextColor)
                          : Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            Icon(
              Icons.chevron_right_rounded,
              color: enabled
                  ? secondaryTextColor
                  : Colors.grey.shade400,
            ),
          ],
        ),
      ),
    ),
  );
}
void _showLocationPicker({
  required String title,
  required List<String> items,
  required String? selectedValue,
  required ValueChanged<String> onSelected,
}) {
  final TextEditingController searchController =
      TextEditingController();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final searchText =
              searchController.text.trim().toLowerCase();

          final filteredItems = items.where((item) {
            return item.toLowerCase().contains(searchText);
          }).toList();

          return Container(
            height:
                MediaQuery.of(context).size.height * 0.72,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),

                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius:
                        BorderRadius.circular(10),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    20,
                    18,
                    20,
                    10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.location_on_outlined,
                          color: primaryOrange,
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                      ),

                      IconButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        icon: const Icon(
                          Icons.close_rounded,
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                  ),
                  child: TextField(
                    controller: searchController,
                    autofocus: false,
                    onChanged: (_) {
                      setSheetState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: 'Search $title...',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                      ),
                      suffixIcon:
                          searchController.text.isNotEmpty
                              ? IconButton(
                                  onPressed: () {
                                    searchController.clear();
                                    setSheetState(() {});
                                  },
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                  ),
                                )
                              : null,
                      filled: true,
                      fillColor: const Color(0xFFF7F7F7),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                Expanded(
                  child: filteredItems.isEmpty
                      ? const Center(
                          child: Text(
                            'No locations found',
                            style: TextStyle(
                              color: secondaryTextColor,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding:
                              const EdgeInsets.fromLTRB(
                            12,
                            4,
                            12,
                            20,
                          ),
                          itemCount:
                              filteredItems.length,
                          itemBuilder:
                              (context, index) {
                            final item =
                                filteredItems[index];

                            final isSelected =
                                item == selectedValue;

                            return ListTile(
                              shape:
                                  RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(
                                  12,
                                ),
                              ),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? primaryOrange
                                          .withOpacity(
                                          0.12,
                                        )
                                      : Colors.grey
                                          .withOpacity(
                                          0.08,
                                        ),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.location_on_outlined,
                                  size: 20,
                                  color: isSelected
                                      ? primaryOrange
                                      : secondaryTextColor,
                                ),
                              ),
                              title: Text(
                                item,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              ),
                              trailing: isSelected
                                  ? const Icon(
                                      Icons.check_circle,
                                      color:
                                          primaryOrange,
                                    )
                                  : const Icon(
                                      Icons
                                          .chevron_right_rounded,
                                      color:
                                          Colors.grey,
                                    ),
                              onTap: () {
                                onSelected(item);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
// ============================================================
// HOME SEARCH AND FILTER METHODS
// ============================================================

List<String> get tenantCountyOptions {
  return kenyaLocations
      .map((location) => location.county)
      .toSet()
      .toList();
}

List<String> get tenantCityOptions {
  if (selectedCounty == null) {
    return [];
  }

  return kenyaLocations
      .where(
        (location) =>
            location.county == selectedCounty,
      )
      .map((location) => location.city)
      .toSet()
      .toList();
}

List<String> get tenantAreaOptions {
  if (selectedCounty == null ||
      selectedCity == null) {
    return [];
  }

  return kenyaLocations
      .where(
        (location) =>
            location.county == selectedCounty &&
            location.city == selectedCity,
      )
      .map((location) => location.area)
      .toSet()
      .toList();
}

Future<void> _openFilters() async {
  final result = await Navigator.push<
      Map<String, dynamic>>(
    context,
    MaterialPageRoute(
      builder: (_) => RentalFiltersScreen(
        bedroomFilter: selectedBedroomFilter,
        propertyTypeFilter:
            selectedPropertyTypeFilter,
        county: selectedCounty,
        city: selectedCity,
        area: selectedArea,
      ),
    ),
  );

  if (result == null || !mounted) {
    return;
  }

  setState(() {
    selectedBedroomFilter =
        result['bedroomFilter'] ?? 'Any';

    selectedPropertyTypeFilter =
        result['propertyTypeFilter'] ?? 'Any';

    selectedBathroomFilter =
        result['bathroomFilter'] ?? 'Any';

    selectedMinRent =
        result['minRent'];

    selectedMaxRent =
        result['maxRent'];

    selectedAvailabilityFilter =
        result['availabilityFilter'] ?? 'Any';

    selectedAmenities =
        List<String>.from(
      result['selectedAmenities'] ?? [],
    );

    selectedCounty =
        result['county'];

    selectedCity =
        result['city'];

    selectedArea =
        result['area'];
  });

  // ----------------------------------------------------------
  // DIRECTLY SHOW SEARCH RESULTS AFTER APPLYING FILTERS
  // ----------------------------------------------------------

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SearchResultsScreen(
        query: '',
        bedroomFilter:
            selectedBedroomFilter,
        bathroomFilter:
            selectedBathroomFilter,
        propertyTypeFilter:
            selectedPropertyTypeFilter,

        county: selectedCounty,
        city: selectedCity,
        area: selectedArea,

        minRent: selectedMinRent,
        maxRent: selectedMaxRent,

        availabilityFilter:
            selectedAvailabilityFilter,

        selectedAmenities:
            selectedAmenities,

        title: 'Matching Homes',
      ),
    ),
  );
}
void performSearch() {
  final query = searchController.text.trim();

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SearchResultsScreen(
        query: query,
        bedroomFilter:
            selectedBedroomFilter,
        bathroomFilter:
            selectedBathroomFilter,
        propertyTypeFilter:
            selectedPropertyTypeFilter,

        county: selectedCounty,
        city: selectedCity,
        area: selectedArea,

        minRent: selectedMinRent,
        maxRent: selectedMaxRent,

        availabilityFilter:
            selectedAvailabilityFilter,

        selectedAmenities:
            selectedAmenities,
      ),
    ),
  );
}

@override
void dispose() {
  searchController.dispose();
  super.dispose();
}
  Widget _buildFilters() {
    final filterCount =
        (selectedBedroomFilter != 'Any' ? 1 : 0) +
        (selectedPropertyTypeFilter != 'Any' ? 1 : 0) +
        (selectedCounty != null ? 1 : 0) +
        (selectedCity != null ? 1 : 0) +
        (selectedArea != null ? 1 : 0);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _openFilters,
            icon: const Icon(
              Icons.tune_rounded,
            ),
            label: Text(
              filterCount == 0
                  ? 'Filters'
                  : 'Filters ($filterCount)',
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: performSearch,
            icon: const Icon(
              Icons.search_rounded,
            ),
            label: const Text(
              'Search',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
  Widget _buildPopularAreas() {
  List<String> areas;

  if (selectedCity != null) {
    areas = kenyaLocations
        .where(
          (location) =>
              location.city == selectedCity &&
              (selectedCounty == null ||
                  location.county == selectedCounty),
        )
        .map((location) => location.area)
        .toSet()
        .toList();
  } else {
    areas = [
      'Kilimani',
      'Kileleshwa',
      'Milimani',
      'Nyali',
      'Kapsoya',
      'Mamboleo',
      'Kiamunyi',
      'Ruiru',
    ];
  }

  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Popular areas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        if (areas.isEmpty)
          const Text(
            'No areas available for this location yet.',
            style: TextStyle(
              color: secondaryTextColor,
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: areas.map(
              (area) {
                return ActionChip(
                  label: Text(area),
                  onPressed: () {
                    openArea(area);
                  },
                );
              },
            ).toList(),
          ),
      ],
    ),
  );
}
  Widget _buildNewHomes() {
  return Padding(
    padding: const EdgeInsets.fromLTRB(
      16,
      26,
      16,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'New rental homes',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        FirestoreRentalProperties(
  selectedCounty: selectedCounty,
  selectedCity: selectedCity,
  selectedArea: selectedArea,
),
      ],
    ),
  );
}
}
// ============================================================
// SEARCH RESULTS SCREEN
// ============================================================

// ============================================================
// SEARCH RESULTS SCREEN
// ============================================================

class SearchResultsScreen extends StatelessWidget {
  final String query;
  final String bedroomFilter;
  final String bathroomFilter;
  final String propertyTypeFilter;

  final String? county;
  final String? city;
  final String? area;

  final int? minRent;
  final int? maxRent;

  final String availabilityFilter;

  final List<String> selectedAmenities;

  final String? title;

  const SearchResultsScreen({
    super.key,
    required this.query,
    required this.bedroomFilter,
    required this.bathroomFilter,
    required this.propertyTypeFilter,
    this.county,
    this.city,
    this.area,
    this.minRent,
    this.maxRent,
    this.availabilityFilter = 'Any',
    this.selectedAmenities = const [],
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final searchQuery = query.trim().toLowerCase();

    return Scaffold(
      backgroundColor: backgroundColor,

      appBar: AppBar(
        title: Text(
          title ?? 'Search Results',
        ),
      ),

      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
          .collection('properties')
          .where(
            'status',
            isEqualTo: 'approved',
          )
          .where(
            'verified',
            isEqualTo: true,
          )
          .snapshots(),

        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Could not load rental homes.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          final filteredDocuments =
              documents.where((doc) {
            final data = doc.data();

            final property =
                rentalPropertyFromFirestore(data);

            // ------------------------------------------------
// SMART SEARCH
// ------------------------------------------------

String remainingSearch = searchQuery;

// Detect bedroom searches such as:
// 2 b
// 2br
// 2 bed
// 2 bedroom
// 2 bedrooms

final bedroomMatch = RegExp(
  r'\b([0-9]+)\s*(b|br|bed|beds|bedroom|bedrooms)\b',
  caseSensitive: false,
).firstMatch(remainingSearch);

int? searchBedrooms;

if (bedroomMatch != null) {
  searchBedrooms =
      int.tryParse(bedroomMatch.group(1)!);

  remainingSearch =
      remainingSearch.replaceFirst(
    bedroomMatch.group(0)!,
    '',
  );
}

// Detect bedsitter / studio searches.

final bedsitterMatch = RegExp(
  r'\b(bed|bedsit|bedsitter|studio)\b',
  caseSensitive: false,
).hasMatch(remainingSearch);

if (bedsitterMatch) {
  remainingSearch = remainingSearch.replaceAll(
    RegExp(
      r'\b(bed|bedsit|bedsitter|studio)\b',
      caseSensitive: false,
    ),
    '',
  );
}

// ------------------------------------------------
// BEDROOM MATCH
// ------------------------------------------------

if (searchBedrooms != null &&
    property.bedrooms != searchBedrooms) {
  return false;
}

// ------------------------------------------------
// BEDSITTER MATCH
// ------------------------------------------------

if (bedsitterMatch &&
    property.bedrooms != 0) {
  return false;
}

// ------------------------------------------------
// SMART PROPERTY TYPE MATCH
// ------------------------------------------------

final propertyTypeText =
    property.propertyType.toLowerCase();

if (remainingSearch.contains('apartment') &&
    !propertyTypeText.contains('apartment')) {
  return false;
}

if ((remainingSearch.contains('stand') ||
        remainingSearch.contains('standalone')) &&
    !propertyTypeText.contains('standalone')) {
  return false;
}

if (remainingSearch.contains('maisonette') &&
    !propertyTypeText.contains('maisonette')) {
  return false;
}

if (remainingSearch.contains('townhouse') &&
    !propertyTypeText.contains('townhouse')) {
  return false;
}

if (remainingSearch.contains('villa') &&
    !propertyTypeText.contains('villa')) {
  return false;
}

if (remainingSearch.contains('gated') &&
    !propertyTypeText.contains('gated')) {
  return false;
}

if (remainingSearch.contains('serviced') &&
    !propertyTypeText.contains('serviced')) {
  return false;
}

// ------------------------------------------------
// LOCATION / GENERAL TEXT SEARCH
// ------------------------------------------------

final countyText =
    data['county']?.toString().toLowerCase() ?? '';

final cityText =
    data['city']?.toString().toLowerCase() ?? '';

final areaText =
    data['area']?.toString().toLowerCase() ?? '';

final titleText =
    property.title.toLowerCase();

final locationText =
    property.location.toLowerCase();

final remainingWords = remainingSearch
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .toList();

for (final word in remainingWords) {
  final matchesWord =
      titleText.contains(word) ||
      locationText.contains(word) ||
      propertyTypeText.contains(word) ||
      countyText.contains(word) ||
      cityText.contains(word) ||
      areaText.contains(word);

  if (!matchesWord) {
    return false;
  }
}

            // ------------------------------------------------
            // COUNTY
            // ------------------------------------------------

            if (county != null &&
                county!.isNotEmpty &&
                data['county']?.toString() != county) {
              return false;
            }

            // ------------------------------------------------
            // CITY
            // ------------------------------------------------

            if (city != null &&
                city!.isNotEmpty &&
                data['city']?.toString() != city) {
              return false;
            }

            // ------------------------------------------------
            // AREA
            // ------------------------------------------------

            if (area != null &&
                area!.isNotEmpty &&
                data['area']?.toString() != area) {
              return false;
            }

            // ------------------------------------------------
            // PROPERTY TYPE
            // ------------------------------------------------

            if (propertyTypeFilter != 'Any' &&
                property.propertyType !=
                    propertyTypeFilter) {
              return false;
            }

            // ------------------------------------------------
            // BEDROOMS
            // ------------------------------------------------

            switch (bedroomFilter) {
              case 'Bedsitter':
              case 'Studio / Bedsitter':
                if (property.bedrooms != 0) {
                  return false;
                }
                break;

              case '1 Bedroom':
                if (property.bedrooms != 1) {
                  return false;
                }
                break;

              case '2 Bedrooms':
                if (property.bedrooms != 2) {
                  return false;
                }
                break;

              case '3 Bedrooms':
                if (property.bedrooms != 3) {
                  return false;
                }
                break;

              case '4 Bedrooms':
                if (property.bedrooms != 4) {
                  return false;
                }
                break;

              case '5 Bedrooms':
                if (property.bedrooms != 5) {
                  return false;
                }
                break;

              case '6+ Bedrooms':
                if (property.bedrooms < 6) {
                  return false;
                }
                break;

              case 'Any':
              default:
                break;
            }

            // ------------------------------------------------
            // BATHROOMS
            // ------------------------------------------------

            switch (bathroomFilter) {
              case '1 Bathroom':
                if (property.bathrooms != 1) {
                  return false;
                }
                break;

              case '2 Bathrooms':
                if (property.bathrooms != 2) {
                  return false;
                }
                break;

              case '3 Bathrooms':
                if (property.bathrooms != 3) {
                  return false;
                }
                break;

              case '4+ Bathrooms':
                if (property.bathrooms < 4) {
                  return false;
                }
                break;

              case 'Any':
              default:
                break;
            }

            // ------------------------------------------------
            // RENT
            // ------------------------------------------------

            if (minRent != null &&
                property.rent < minRent!) {
              return false;
            }

            if (maxRent != null &&
                property.rent > maxRent!) {
              return false;
            }

            // ------------------------------------------------
            // AVAILABILITY
            // ------------------------------------------------

            if (availabilityFilter != 'Any' &&
                property.availability !=
                    availabilityFilter) {
              return false;
            }

            // ------------------------------------------------
            // AMENITIES
            // ------------------------------------------------

            if (selectedAmenities.isNotEmpty) {
              final propertyAmenities =
                  property.amenities
                      .map(
                        (amenity) =>
                            amenity.toLowerCase(),
                      )
                      .toSet();

              final requiredAmenities =
                  selectedAmenities
                      .map(
                        (amenity) =>
                            amenity.toLowerCase(),
                      )
                      .toList();

              final hasAllAmenities =
                  requiredAmenities.every(
                propertyAmenities.contains,
              );

              if (!hasAllAmenities) {
                return false;
              }
            }

            return true;
          }).toList();

          // --------------------------------------------------
          // NO RESULTS
          // --------------------------------------------------

          if (filteredDocuments.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_off_rounded,
                      size: 64,
                      color: Colors.grey.shade400,
                    ),

                    const SizedBox(height: 16),

                    const Text(
                      'No homes found',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),

                    const SizedBox(height: 8),

                    const Text(
                      'Try changing your filters or search area.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          // --------------------------------------------------
          // CONVERT FIRESTORE DOCUMENTS
          // --------------------------------------------------

          final properties = filteredDocuments
              .map(
                (doc) => rentalPropertyFromFirestore(
                  doc.data(),
                ),
              )
              .toList();

          // --------------------------------------------------
          // RESULTS
          // --------------------------------------------------

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              16,
              16,
              16,
              30,
            ),
            children: [
              Text(
                '${properties.length} ${properties.length == 1 ? 'home' : 'homes'} found',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),

              const SizedBox(height: 14),

              ...properties.map(
                (property) => Padding(
                  padding: const EdgeInsets.only(
                    bottom: 16,
                  ),
                  child: PropertyCard(
                    property: property,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
// ============================================================
// PROPERTY CARD
// ============================================================

class PropertyCard extends StatelessWidget {
  final RentalProperty property;

  const PropertyCard({
    super.key,
    required this.property,
  });

  @override
  Widget build(BuildContext context) {
    final availability = property.availability;

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: Colors.grey.shade200,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PropertyDetailsScreen(
                property: property,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  height: 190,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius:
                        const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                  ),
                  child: property.photoPaths.isNotEmpty
                      ? (property.photoPaths.first.startsWith('http')
                          ? Image.network(
                              property.photoPaths.first,
                              fit: BoxFit.cover,
                              errorBuilder:
                                  (context, error, stackTrace) {
                                return const Icon(
                                  Icons.broken_image,
                                  size: 70,
                                  color: Colors.grey,
                                );
                              },
                            )
                          : Image.file(
                              File(property.photoPaths.first),
                              fit: BoxFit.cover,
                            ))
                      : const Icon(
                          Icons.apartment,
                          size: 70,
                          color: Colors.grey,
                        ),
                ),

                // AVAILABILITY BADGE
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _availabilityColor(
                        availability,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _availabilityIcon(
                            availability,
                          ),
                          size: 14,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          availability,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Positioned(
  top: 8,
  right: 8,
  child: ValueListenableBuilder<Set<String>>(
    valueListenable: SavedProperties.savedIds,
    builder: (context, savedIds, _) {
      final saved = savedIds.contains(property.id);

      return CircleAvatar(
        backgroundColor: Colors.white,
        child: IconButton(
          onPressed: () {
            SavedProperties.toggle(property.id);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  saved
                      ? 'Removed from saved homes'
                      : 'Saved to your homes',
                ),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          icon: Icon(
            saved
                ? Icons.favorite
                : Icons.favorite_border,
            color: saved ? primaryOrange : textColor,
          ),
        ),
      );
    },
  ),
),

              ],
            ),
// HORIZONTAL PHOTO THUMBNAILS
            if (property.photoPaths.length > 1)
              SizedBox(
                height: 76,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  itemCount: property.photoPaths.length - 1,
                  itemBuilder: (context, index) {
                    final photoPath =
                        property.photoPaths[index + 1];

                    return Container(
                      width: 76,
                      margin: const EdgeInsets.only(
                        right: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.grey.shade200,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: photoPath.startsWith('http')
                          ? Image.network(
                              photoPath,
                              fit: BoxFit.cover,
                              errorBuilder: (
                                context,
                                error,
                                stackTrace,
                              ) {
                                return const Icon(
                                  Icons.broken_image,
                                  color: Colors.grey,
                                );
                              },
                            )
                          : Image.file(
                              File(photoPath),
                              fit: BoxFit.cover,
                              errorBuilder: (
                                context,
                                error,
                                stackTrace,
                              ) {
                                return const Icon(
                                  Icons.broken_image,
                                  color: Colors.grey,
                                );
                              },
                            ),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    property.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 5),

                                  Row(
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: secondaryTextColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        property.location,
                        style: const TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // PROPERTY TYPE
                Row(
                  children: [
                    const Icon(
                      Icons.home_work_outlined,
                      size: 16,
                      color: secondaryTextColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      property.propertyType,
                      style: const TextStyle(
                        color: secondaryTextColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                if (property.propertySetting.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_city_outlined,
                        size: 16,
                        color: secondaryTextColor,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          property.propertySetting,
                          style: const TextStyle(
                            color: secondaryTextColor,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                if (property.availableFrom != null &&
                    (availability == 'Available this month' ||
                        availability == 'Available next month')) ...[
                Row(
                  children: [
                    const Icon(
                      Icons.event_available_outlined,
                      size: 16,
                      color: primaryOrange,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        'Available from ${_formatAvailabilityDate(property.availableFrom!)}',
                        style: const TextStyle(
                          color: primaryOrange,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
                  Row(
                    children: [
                      _smallInfo(
                        Icons.bed_outlined,
                        property.bedrooms == 0
                            ? 'Bedsitter'
                            : '${property.bedrooms} bed',
                      ),
                      const SizedBox(width: 12),
                      _smallInfo(
                        Icons.bathtub_outlined,
                        '${property.bathrooms} bath',
                      ),
                      const SizedBox(width: 12),
                      _smallInfo(
                        Icons.square_foot,
                        '${property.size} sq ft',
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Text(
                        'KSh ${property.rent}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: primaryOrange,
                        ),
                      ),
                      const Text(
                        ' / month',
                        style: TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),
                      const Spacer(),
                      const Icon(
                        Icons.arrow_forward,
                        color: primaryOrange,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _availabilityColor(String availability) {
    switch (availability) {
      case 'Available now':
        return availableGreen;

      case 'Available this month':
        return Colors.orange;

      case 'Available next month':
        return Colors.blue;

      case 'Reserved':
        return Colors.amber.shade800;

      case 'Rented / Occupied':
        return Colors.red;

      default:
        return Colors.grey;
    }
  }

  IconData _availabilityIcon(String availability) {
    switch (availability) {
      case 'Available now':
        return Icons.check_circle_outline;

      case 'Available this month':
        return Icons.event_available_outlined;

      case 'Available next month':
        return Icons.calendar_month_outlined;

      case 'Reserved':
        return Icons.lock_outline;

      case 'Rented / Occupied':
        return Icons.home_work_outlined;

      default:
        return Icons.info_outline;
    }
  }
  String _formatAvailabilityDate(DateTime date) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

  Widget _smallInfo(
    IconData icon,
    String text,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: secondaryTextColor,
        ),
        const SizedBox(width: 3),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            color: secondaryTextColor,
          ),
        ),
      ],
    );
  }
}
// ============================================================
// PROPERTY DETAILS SCREEN
// ============================================================

class PropertyDetailsScreen extends StatelessWidget {
  final RentalProperty property;

  const PropertyDetailsScreen({
    super.key,
    required this.property,
  });

  Future<String?> _getUserRole() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return null;
    }

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    return doc.data()?['role'] as String?;
  }

  Future<void> _requestViewing(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;

  // ------------------------------------------------------------
  // NOT LOGGED IN
  // ------------------------------------------------------------

  if (user == null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AuthScreen(),
      ),
    );
    return;
  }

  try {
    final role = await _getUserRole();

    if (!context.mounted) return;

    // ----------------------------------------------------------
    // ONLY TENANTS CAN REQUEST VIEWINGS
    // ----------------------------------------------------------

    if (role != 'tenant') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            role == null
                ? 'Please complete your account setup first.'
                : 'Only tenant accounts can request property viewings.',
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewingRequestScreen(
          property: property,
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Unable to check your account. Please try again.',
        ),
      ),
    );
  }
}

  Future<void> _contactManager(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;

  // ------------------------------------------------------------
  // NOT LOGGED IN
  // ------------------------------------------------------------

  if (user == null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AuthScreen(),
      ),
    );
    return;
  }

  try {
    final role = await _getUserRole();

    if (!context.mounted) return;

    // ----------------------------------------------------------
    // ONLY TENANTS CAN CONTACT PROPERTY MANAGER
    // ----------------------------------------------------------

    if (role != 'tenant') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            role == null
                ? 'Please complete your account setup first.'
                : 'Only tenant accounts can contact the property manager.',
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ContactManagerScreen(
          property: property,
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Unable to check your account. Please try again.',
        ),
      ),
    );
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Property Details'),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // PROPERTY PHOTOS
            if (property.photoPaths.isNotEmpty)
              _TenantPhotoGallery(
                photoPaths: property.photoPaths,
              )
            else
              Container(
                height: 250,
                width: double.infinity,
                color: Colors.grey.shade200,
                child: const Icon(
                  Icons.apartment,
                  size: 90,
                  color: Colors.grey,
                ),
              ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // TITLE
                  Text(
                    property.title,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  // LOCATION
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        color: primaryOrange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          property.location,
                          style: const TextStyle(
                            fontSize: 16,
                            color: secondaryTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // PROPERTY TYPE
Container(
  width: double.infinity,
  padding: const EdgeInsets.all(14),
  decoration: BoxDecoration(
    color: Colors.orange.shade50,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: Colors.orange.shade100,
    ),
  ),
  child: Row(
    children: [
      const Icon(
        Icons.home_work_outlined,
        color: primaryOrange,
        size: 24,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Property Type',
              style: TextStyle(
                fontSize: 12,
                color: secondaryTextColor,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              property.propertyType,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    ],
  ),
),
if (property.propertySetting.isNotEmpty) ...[
  const SizedBox(height: 12),
  Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: Colors.orange.shade100,
      ),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.location_city_outlined,
          color: primaryOrange,
          size: 24,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Property Setting',
                style: TextStyle(
                  fontSize: 12,
                  color: secondaryTextColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                property.propertySetting,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  ),
],
const SizedBox(height: 20),

// ============================================================
// AVAILABILITY
// ============================================================
Container(
  width: double.infinity,
  padding: const EdgeInsets.all(14),
  decoration: BoxDecoration(
    color: _availabilityBackgroundColor(
      property.availability,
    ),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: _availabilityBorderColor(
        property.availability,
      ),
    ),
  ),
  child: Row(
    children: [
      Icon(
        _availabilityIcon(
          property.availability,
        ),
        color: _availabilityColor(
          property.availability,
        ),
        size: 26,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Availability',
              style: TextStyle(
                fontSize: 12,
                color: secondaryTextColor,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              property.availability,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _availabilityColor(
                  property.availability,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ),
),
if (property.availableFrom != null &&
                (property.availability == 'Available this month' ||
                    property.availability == 'Available next month')) ...[
              const SizedBox(height: 4),
              Text(
                'Available from ${_formatAvailabilityDate(property.availableFrom!)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: _availabilityColor(property.availability),
                ),
              ),
            ],
const SizedBox(height: 24),

// PROPERTY FEATURES
Row(
                    children: [
                      _detailItem(
                        Icons.bed_outlined,
                        '${property.bedrooms} Bedrooms',
                      ),
                      const SizedBox(width: 20),
                      _detailItem(
                        Icons.bathtub_outlined,
                        '${property.bathrooms} Bathrooms',
                      ),
                      const SizedBox(width: 20),
                      _detailItem(
                        Icons.square_foot,
                        '${property.size} m²',
                      ),
                    ],
                  ),

                  const SizedBox(height: 28),

                  // DESCRIPTION
                  const Text(
                    'Description',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    property.description.isEmpty
                        ? 'No description available.'
                        : property.description,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 28),

                  // AMENITIES
                  if (property.amenities.isNotEmpty) ...[
                    const Text(
                      'Amenities',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: property.amenities.map((amenity) {
                        return Chip(
                          label: Text(amenity),
                          avatar: const Icon(
                            Icons.check_circle_outline,
                            size: 18,
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 28),
                  ],

                  // REQUEST VIEWING
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        _requestViewing(context);
                      },
                      icon: const Icon(
                        Icons.calendar_month,
                      ),
                      label: const Text(
                        'Request a Viewing',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryOrange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // CONTACT MANAGER
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _contactManager(context);
                      },
                      icon: const Icon(
                        Icons.phone_outlined,
                      ),
                      label: const Text(
                        'Contact Manager',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: primaryOrange,
                        side: const BorderSide(
                          color: primaryOrange,
                        ),
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  String _formatAvailabilityDate(DateTime date) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  return '${date.day} ${months[date.month - 1]} ${date.year}';
}
  Color _availabilityColor(String availability) {
  switch (availability) {
    case 'Available now':
      return availableGreen;

    case 'Available this month':
      return Colors.orange;

    case 'Available next month':
      return Colors.blue;

    case 'Reserved':
      return Colors.amber.shade800;

    case 'Rented / Occupied':
      return Colors.red;

    default:
      return Colors.grey;
  }
}

Color _availabilityBackgroundColor(String availability) {
  switch (availability) {
    case 'Available now':
      return Colors.green.shade50;

    case 'Available this month':
      return Colors.orange.shade50;

    case 'Available next month':
      return Colors.blue.shade50;

    case 'Reserved':
      return Colors.amber.shade50;

    case 'Rented / Occupied':
      return Colors.red.shade50;

    default:
      return Colors.grey.shade100;
  }
}

Color _availabilityBorderColor(String availability) {
  switch (availability) {
    case 'Available now':
      return Colors.green.shade100;

    case 'Available this month':
      return Colors.orange.shade100;

    case 'Available next month':
      return Colors.blue.shade100;

    case 'Reserved':
      return Colors.amber.shade100;

    case 'Rented / Occupied':
      return Colors.red.shade100;

    default:
      return Colors.grey.shade200;
  }
}

IconData _availabilityIcon(String availability) {
  switch (availability) {
    case 'Available now':
      return Icons.check_circle_outline;

    case 'Available this month':
      return Icons.event_available_outlined;

    case 'Available next month':
      return Icons.calendar_month_outlined;

    case 'Reserved':
      return Icons.lock_outline;

    case 'Rented / Occupied':
      return Icons.home_work_outlined;

    default:
      return Icons.info_outline;
  }
}

  Widget _detailItem(
    IconData icon,
    String text,
  ) {
    return Expanded(
      child: Column(
        children: [
          Icon(
            icon,
            color: primaryOrange,
            size: 25,
          ),
          const SizedBox(height: 5),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
// ============================================================
// SEARCH RESULTS
// ============================================================

// ============================================================
// RENTAL FILTERS SCREEN
// ============================================================

class RentalFiltersScreen extends StatefulWidget {
  final String bedroomFilter;
  final String propertyTypeFilter;
  final String? county;
  final String? city;
  final String? area;

  // STEP 2 FILTERS
  final String bathroomFilter;
  final int? minRent;
  final int? maxRent;
  final String availabilityFilter;
  final List<String> selectedAmenities;

  const RentalFiltersScreen({
    super.key,
    required this.bedroomFilter,
    required this.propertyTypeFilter,
    this.county,
    this.city,
    this.area,

    // STEP 2 FILTERS
    this.bathroomFilter = 'Any',
    this.minRent,
    this.maxRent,
    this.availabilityFilter = 'Any',
    this.selectedAmenities = const [],
  });

  @override
  State<RentalFiltersScreen> createState() =>
      _RentalFiltersScreenState();
}

class _RentalFiltersScreenState
    extends State<RentalFiltersScreen> {
  late String selectedBedroomFilter;
  late String selectedPropertyTypeFilter;

  String? selectedCounty;
  String? selectedCity;
  String? selectedArea;

  // ============================================================
  // STEP 2 FILTER STATE
  // ============================================================

  late String selectedBathroomFilter;
  late String selectedAvailabilityFilter;

  int? selectedMinRent;
  int? selectedMaxRent;

  late Set<String> selectedAmenities;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    selectedBedroomFilter = widget.bedroomFilter;
    selectedPropertyTypeFilter =
        widget.propertyTypeFilter;

    selectedCounty = widget.county;
    selectedCity = widget.city;
    selectedArea = widget.area;

    // STEP 2
    selectedBathroomFilter =
        widget.bathroomFilter;

    selectedMinRent = widget.minRent;
    selectedMaxRent = widget.maxRent;

    selectedAvailabilityFilter =
        widget.availabilityFilter;

    selectedAmenities =
        Set<String>.from(widget.selectedAmenities);
  }

  // ============================================================
  // LOCATION OPTIONS
  // ============================================================

  List<String> get countyOptions {
    return kenyaLocations
        .map((location) => location.county)
        .toSet()
        .toList();
  }

  List<String> get cityOptions {
    if (selectedCounty == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county ==
              selectedCounty,
        )
        .map((location) => location.city)
        .toSet()
        .toList();
  }

  List<String> get areaOptions {
    if (selectedCounty == null ||
        selectedCity == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county ==
                  selectedCounty &&
              location.city ==
                  selectedCity,
        )
        .map((location) => location.area)
        .toSet()
        .toList();
  }

  // ============================================================
  // CLEAR ALL FILTERS
  // ============================================================

  void clearAll() {
    setState(() {
      selectedBedroomFilter = 'Any';
      selectedPropertyTypeFilter = 'Any';

      selectedCounty = null;
      selectedCity = null;
      selectedArea = null;

      // STEP 2
      selectedBathroomFilter = 'Any';
      selectedMinRent = null;
      selectedMaxRent = null;
      selectedAvailabilityFilter = 'Any';
      selectedAmenities.clear();
    });
  }

  // ============================================================
  // APPLY FILTERS
  // ============================================================

  void applyFilters() {
    Navigator.pop(
      context,
      {
        'bedroomFilter':
            selectedBedroomFilter,

        'propertyTypeFilter':
            selectedPropertyTypeFilter,

        'county': selectedCounty,
        'city': selectedCity,
        'area': selectedArea,

        // STEP 2
        'bathroomFilter':
            selectedBathroomFilter,

        'minRent':
            selectedMinRent,

        'maxRent':
            selectedMaxRent,

        'availabilityFilter':
            selectedAvailabilityFilter,

        'selectedAmenities':
            selectedAmenities.toList(),
      },
    );
  }

  // ============================================================
  // RENT OPTIONS
  // ============================================================

  final List<int> rentOptions = [
    5000,
    10000,
    15000,
    20000,
    25000,
    30000,
    40000,
    50000,
    75000,
    100000,
    150000,
    200000,
  ];

  String _rentLabel(int? amount) {
    if (amount == null) {
      return 'Any';
    }

    return 'KSh ${amount.toString()}';
  }

  // ============================================================
  // AMENITIES
  // ============================================================

  final List<String> amenityOptions = [
    'Parking',
    'Wi-Fi',
    'Security',
    'Water',
    'Balcony',
    'Ensuite',
    'Furnished',
    'CCTV',
    'Generator',
  ];

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    const bedroomFilters = [
      'Any',
      'Bedsitter / Studio',
      '1 Bedroom',
      '2 Bedrooms',
      '3 Bedrooms',
      '4 Bedrooms',
      '5 Bedrooms',
      '6+ Bedrooms',
    ];

    const propertyTypes = [
      'Any',
      'Apartment',
      'Standalone House',
      'Maisonette',
      'Townhouse',
      'Villa',
      'Gated Community',
      'Serviced Apartment',
      'Studio / Bedsitter',
      'Other',
    ];

    const bathroomFilters = [
      'Any',
      '1 Bathroom',
      '2 Bathrooms',
      '3 Bathrooms',
      '4+ Bathrooms',
    ];

    const availabilityOptions = [
      'Any',
      'Available now',
      'Available this month',
      'Available next month',
      'Reserved',
      'Rented / Occupied',
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Filter Homes'),
        actions: [
          TextButton(
            onPressed: clearAll,
            child: const Text('Clear'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [

                  // ==================================================
                  // PROPERTY TYPE
                  // ==================================================

                  const Text(
                    'Property Type',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    value:
                        selectedPropertyTypeFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Property Type',
                      prefixIcon: const Icon(
                        Icons.home_work_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: propertyTypes
                        .map(
                          (type) =>
                              DropdownMenuItem<String>(
                            value: type,
                            child: Text(type),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        selectedPropertyTypeFilter =
                            value;
                      });
                    },
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // BEDROOMS
                  // ==================================================

                  const Text(
                    'Bedrooms',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    value:
                        selectedBedroomFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Bedrooms',
                      prefixIcon: const Icon(
                        Icons.bed_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: bedroomFilters
                        .map(
                          (bedroom) =>
                              DropdownMenuItem<String>(
                            value: bedroom,
                            child: Text(bedroom),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        selectedBedroomFilter =
                            value;
                      });
                    },
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // BATHROOMS
                  // ==================================================

                  const Text(
                    'Bathrooms',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    value:
                        selectedBathroomFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Bathrooms',
                      prefixIcon: const Icon(
                        Icons.bathtub_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: bathroomFilters
                        .map(
                          (bathroom) =>
                              DropdownMenuItem<String>(
                            value: bathroom,
                            child: Text(bathroom),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        selectedBathroomFilter =
                            value;
                      });
                    },
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // LOCATION
                  // ==================================================

                  const Text(
                    'Location',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    value: selectedCounty,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'County',
                      prefixIcon: const Icon(
                        Icons.location_on_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: countyOptions
                        .map(
                          (county) =>
                              DropdownMenuItem<String>(
                            value: county,
                            child: Text(county),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        selectedCounty = value;
                        selectedCity = null;
                        selectedArea = null;
                      });
                    },
                  ),

                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: selectedCity,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'City',
                      prefixIcon: const Icon(
                        Icons.location_city_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: cityOptions
                        .map(
                          (city) =>
                              DropdownMenuItem<String>(
                            value: city,
                            child: Text(city),
                          ),
                        )
                        .toList(),
                    onChanged: selectedCounty == null
                        ? null
                        : (value) {
                            setState(() {
                              selectedCity =
                                  value;
                              selectedArea = null;
                            });
                          },
                  ),

                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: selectedArea,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Area',
                      prefixIcon: const Icon(
                        Icons.place_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: areaOptions
                        .map(
                          (area) =>
                              DropdownMenuItem<String>(
                            value: area,
                            child: Text(area),
                          ),
                        )
                        .toList(),
                    onChanged: selectedCity == null
                        ? null
                        : (value) {
                            setState(() {
                              selectedArea = value;
                            });
                          },
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // RENT RANGE
                  // ==================================================

                  const Text(
                    'Rent Range',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Row(
                    children: [
                      Expanded(
                        child:
                            DropdownButtonFormField<int?>(
                          value: selectedMinRent,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Minimum',
                            prefixIcon:
                                const Icon(
                              Icons
                                  .payments_outlined,
                            ),
                            border:
                                OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(
                                10,
                              ),
                            ),
                            contentPadding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal: 10,
                              vertical: 12,
                            ),
                          ),
                          items: [
                            const DropdownMenuItem<
                                int?>(
                              value: null,
                              child: Text('Any'),
                            ),
                            ...rentOptions.map(
                              (amount) =>
                                  DropdownMenuItem<
                                      int?>(
                                value: amount,
                                child: Text(
                                  _rentLabel(
                                    amount,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              selectedMinRent =
                                  value;

                              if (selectedMaxRent !=
                                      null &&
                                  value != null &&
                                  selectedMaxRent! <
                                      value) {
                                selectedMaxRent =
                                    null;
                              }
                            });
                          },
                        ),
                      ),

                      const SizedBox(width: 10),

                      Expanded(
                        child:
                            DropdownButtonFormField<int?>(
                          value: selectedMaxRent,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Maximum',
                            prefixIcon:
                                const Icon(
                              Icons
                                  .payments_outlined,
                            ),
                            border:
                                OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(
                                10,
                              ),
                            ),
                            contentPadding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal: 10,
                              vertical: 12,
                            ),
                          ),
                          items: [
                            const DropdownMenuItem<
                                int?>(
                              value: null,
                              child: Text('Any'),
                            ),
                            ...rentOptions.map(
                              (amount) =>
                                  DropdownMenuItem<
                                      int?>(
                                value: amount,
                                child: Text(
                                  _rentLabel(
                                    amount,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              selectedMaxRent =
                                  value;

                              if (selectedMinRent !=
                                      null &&
                                  value != null &&
                                  selectedMinRent! >
                                      value) {
                                selectedMinRent =
                                    null;
                              }
                            });
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // AVAILABILITY
                  // ==================================================

                  const Text(
                    'Availability',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  DropdownButtonFormField<String>(
                    value:
                        selectedAvailabilityFilter,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Availability',
                      prefixIcon: const Icon(
                        Icons.event_available_outlined,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: availabilityOptions
                        .map(
                          (availability) =>
                              DropdownMenuItem<String>(
                            value: availability,
                            child: Text(
                              availability,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }

                      setState(() {
                        selectedAvailabilityFilter =
                            value;
                      });
                    },
                  ),

                  const SizedBox(height: 20),

                  // ==================================================
                  // AMENITIES
                  // ==================================================

                  const Text(
                    'Amenities',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.grey.shade300,
                      ),
                      borderRadius:
                          BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: amenityOptions.map(
                        (amenity) {
                          final isSelected =
                              selectedAmenities
                                  .contains(amenity);

                          return CheckboxListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets
                                    .symmetric(
                              horizontal: 8,
                            ),
                            title: Text(amenity),
                            value: isSelected,
                            activeColor:
                                primaryOrange,
                            onChanged: (value) {
                              setState(() {
                                if (value == true) {
                                  selectedAmenities
                                      .add(amenity);
                                } else {
                                  selectedAmenities
                                      .remove(amenity);
                                }
                              });
                            },
                          );
                        },
                      ).toList(),
                    ),
                  ),

                  const SizedBox(height: 100),
                ],
              ),
            ),

            // ========================================================
            // APPLY BUTTON
            // ========================================================

            Container(
              padding: const EdgeInsets.fromLTRB(
                16,
                10,
                16,
                16,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .scaffoldBackgroundColor,
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 8,
                    color: Colors.black12,
                  ),
                ],
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: applyFilters,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 13,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'Apply Filters',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// ============================================================
// CONTACT MANAGER
// ============================================================

class ContactManagerScreen extends StatelessWidget {
  final RentalProperty property;

  const ContactManagerScreen({
    super.key,
    required this.property,
  });

  void showMessage(
    BuildContext context,
    String message,
  ) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Manager'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ----------------------------------------------------
          // MANAGER ICON
          // ----------------------------------------------------

          CircleAvatar(
            radius: 42,
            backgroundColor: primaryOrange,
            child: const Icon(
              Icons.person,
              size: 45,
              color: Colors.white,
            ),
          ),

          const SizedBox(height: 15),

          // ----------------------------------------------------
          // MANAGER NAME
          // ----------------------------------------------------

          Center(
            child: Text(
              property.ownerName.trim().isNotEmpty
                  ? property.ownerName
                  : property.managedByType == 'agent'
                      ? 'Property Agent'
                      : 'Property Owner',
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          const SizedBox(height: 5),

          // ----------------------------------------------------
          // PROPERTY TITLE
          // ----------------------------------------------------

          Center(
            child: Text(
              property.title,
              style: const TextStyle(
                color: secondaryTextColor,
              ),
            ),
          ),

          const SizedBox(height: 25),

          // ----------------------------------------------------
          // MESSAGE BOX
          // ----------------------------------------------------

          TextField(
            maxLines: 5,
            decoration: InputDecoration(
              hintText:
                  'Write a message to the property manager...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),

          const SizedBox(height: 15),

          // ----------------------------------------------------
          // CALL PROPERTY MANAGER
          // ----------------------------------------------------

          _contactButton(
            context,
            Icons.phone,
            'Call Property Manager',
            property.ownerPhone.trim().isEmpty
                ? 'Phone number is not available.'
                : property.ownerPhone,
            isCallButton: true,
          ),

          const SizedBox(height: 10),

          // ----------------------------------------------------
          // WHATSAPP
          // ----------------------------------------------------

          _contactButton(
            context,
            Icons.chat,
            'Message on WhatsApp',
            property.ownerPhone.trim().isEmpty
                ? 'Phone number is not available.'
                : property.ownerPhone,
            customIcon: Image.asset(
              'assets/icons/whatsapp.png',
              width: 24,
              height: 24,
            ),
            isWhatsAppButton: true,
            propertyTitle: property.title,
          ),

          const SizedBox(height: 10),

          // ----------------------------------------------------
          // EMAIL
          // ----------------------------------------------------

                    _contactButton(
            context,
            Icons.email_outlined,
            'Send Email',
            property.ownerEmail.trim().isEmpty
                ? 'Email address is not available.'
                : property.ownerEmail,
            isEmailButton: true,
            propertyTitle: property.title,
          ),

          const SizedBox(height: 25),

          // ----------------------------------------------------
          // SAFETY NOTICE
          // ----------------------------------------------------

          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.security,
                  color: primaryOrange,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'For your safety, avoid sending money before viewing and verifying a property.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CONTACT BUTTON
  // ============================================================

  Widget _contactButton(
    BuildContext context,
    IconData icon,
    String title,
    String message, {
    bool isCallButton = false,
    bool isWhatsAppButton = false,
    bool isEmailButton = false,
    Widget? customIcon,
    String propertyTitle = '',
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () {
          if (isCallButton) {
  _showCallDialog(
    context,
    message,
  );
} else if (isWhatsAppButton) {
  _openWhatsApp(
    context,
    message,
    propertyTitle,
  );

} else if (isEmailButton) {
  _openEmail(
    context,
    message,
    propertyTitle,
  );
} else {
  showMessage(
    context,
    message,
  );
}
        },
        icon: customIcon ?? Icon(icon),
        label: Text(title),
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryOrange,
          padding: const EdgeInsets.symmetric(
            vertical: 15,
          ),
        ),
      ),
    );
  }
  // ============================================================
// OPEN EMAIL
// ============================================================

Future<void> _openEmail(
  BuildContext context,
  String email,
  String propertyTitle,
) async {
  final address = email.trim();

  if (address.isEmpty ||
      address == 'Email contact will be connected next.') {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.email_outlined,
                color: primaryOrange,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Email Contact',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'The property manager has not provided an email address.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    );

    return;
  }

  final subject = Uri.encodeComponent(
    'RentalApp Property Viewing - $propertyTitle',
  );

  final body = Uri.encodeComponent(
    'Hello, I am interested in viewing '
    '$propertyTitle on RentalApp. '
    'Please let me know when I can arrange a viewing.',
  );

  final uri = Uri.parse(
    'mailto:$address?subject=$subject&body=$body',
  );

  try {
    await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    if (context.mounted) {
      showMessage(
        context,
        'Unable to open the email application.',
      );
    }
  }
}

  // ============================================================
  // OPEN WHATSAPP
  // ============================================================

  Future<void> _openWhatsApp(
    BuildContext context,
    String phoneNumber,
    String propertyTitle,
  ) async {
    final rawNumber = phoneNumber.trim();

    // ----------------------------------------------------------
    // PHONE NUMBER NOT AVAILABLE
    // ----------------------------------------------------------

    if (rawNumber.isEmpty ||
        rawNumber == 'Phone number is not available.') {
      showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.chat_outlined,
                  color: primaryOrange,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'WhatsApp Contact',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: const Text(
              'The property manager has not provided a WhatsApp phone number.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                },
                child: const Text('Close'),
              ),
            ],
          );
        },
      );

      return;
    }

    // ----------------------------------------------------------
    // CLEAN PHONE NUMBER
    // ----------------------------------------------------------

    String number = rawNumber.replaceAll(
      RegExp(r'[^0-9+]'),
      '',
    );

    if (number.startsWith('+')) {
      number = number.substring(1);
    }

    if (number.startsWith('0')) {
      number = '254${number.substring(1)}';
    }

    if (!number.startsWith('254')) {
      showMessage(
        context,
        'Please check the property manager phone number.',
      );
      return;
    }

    // ----------------------------------------------------------
    // WHATSAPP MESSAGE
    // ----------------------------------------------------------

    final message =
        'Hello, I am interested in viewing '
        '$propertyTitle on RentalApp. '
        'Please let me know when I can arrange a viewing.';

    final encodedMessage =
        Uri.encodeComponent(message);

    final uri = Uri.parse(
      'https://wa.me/$number?text=$encodedMessage',
    );

    try {
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (context.mounted) {
        showMessage(
          context,
          'Unable to open WhatsApp.',
        );
      }
    }
  }
}
void _showCallDialog(
  BuildContext context,
  String phoneNumber,
) {
  final number = phoneNumber.trim();

  if (number.isEmpty ||
      number == 'Phone number is not available.') {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Phone Number',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'The property manager has not provided a phone number.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text(
                'Close',
              ),
            ),
          ],
        );
      },
    );

    return;
  }

  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            24,
            28,
            24,
            20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: primaryOrange.withValues(
                    alpha: 0.12,
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.phone,
                  size: 38,
                  color: primaryOrange,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Property Manager',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Call this number?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondaryTextColor,
                ),
              ),
              const SizedBox(height: 18),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                final uri = Uri.parse(
                  'tel:${number.trim()}',
                );

                try {
                  await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Unable to open the phone dialer.',
                      ),
                    ),
                  );
                  }
                }
              },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                    horizontal: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.phone_outlined,
                        color: primaryOrange,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          number,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: primaryOrange,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                      final uri = Uri.parse(
                        'tel:${number.trim()}',
                      );

                      try {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Unable to open the phone dialer.',
                              ),
                            ),
                          );
                        }
                      }
                    },
                  icon: const Icon(
                    Icons.call,
                  ),
                  label: const Text(
                    'Call Now',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 15,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                },
                child: const Text(
                  'Close',
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
// ============================================================
// VIEWING REQUEST
// ============================================================

class ViewingRequestScreen
    extends StatefulWidget {
  final RentalProperty property;

  const ViewingRequestScreen({
    super.key,
    required this.property,
  });

  @override
  State<ViewingRequestScreen> createState() =>
      _ViewingRequestScreenState();
}

class _ViewingRequestScreenState
    extends State<ViewingRequestScreen> {
  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final messageController =
      TextEditingController();

  DateTime? selectedDate;
  String? selectedTime;
  bool _scheduleLoading = true;
  bool _scheduleLoadFailed = false;

  Map<String, dynamic> _viewingSchedule = {};

  static const Map<int, String> _weekdayKeys = {
    DateTime.monday: 'monday',
    DateTime.tuesday: 'tuesday',
    DateTime.wednesday: 'wednesday',
    DateTime.thursday: 'thursday',
    DateTime.friday: 'friday',
    DateTime.saturday: 'saturday',
    DateTime.sunday: 'sunday',
  };

  @override
  void initState() {
    super.initState();
    _loadViewingSchedule();
  }

    Future<void> _loadViewingSchedule() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('properties')
          .doc(widget.property.id)
          .get();

      if (!doc.exists || doc.data() == null) {
        throw Exception('Property not found');
      }

      final rawSchedule = doc.data()!['viewingSchedule'];

      // 👇 THIS IS THE FIX: If the schedule doesn't exist or is empty,
      // it is NOT a network error. It just means the landlord hasn't
      // set it up yet. We set _scheduleLoadFailed to false.
      if (rawSchedule is! Map || rawSchedule.isEmpty) {
        if (!mounted) return;
        setState(() {
          _scheduleLoading = false;
          _scheduleLoadFailed = false; 
          _viewingSchedule = {};
        });
        return;
      }

      if (!mounted) return;

      setState(() {
        _viewingSchedule = Map<String, dynamic>.from(rawSchedule);
        _scheduleLoading = false;
        _scheduleLoadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scheduleLoading = false;
        _scheduleLoadFailed = true;
      });
    }
  }

  int? _minutesFromTime(String value) {
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})\s*(AM|PM)$',
      caseSensitive: false,
    ).firstMatch(value.trim());

    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final period = match.group(3)!.toUpperCase();

    if (hour < 1 || hour > 12 || minute > 59) {
      return null;
    }

    if (period == 'AM') {
      if (hour == 12) hour = 0;
    } else if (hour != 12) {
      hour += 12;
    }

    return hour * 60 + minute;
  }

  Map<String, dynamic>? _scheduleForDate(DateTime date) {
    final key = _weekdayKeys[date.weekday];
    final value = _viewingSchedule[key];

    if (value is! Map) return null;

    return Map<String, dynamic>.from(value);
  }

  List<String> _availableTimesForDate(DateTime date) {
    final day = _scheduleForDate(date);

    if (day == null || day['enabled'] != true) {
      return [];
    }

    final start = _minutesFromTime(
      day['start']?.toString() ?? '',
    );
    final end = _minutesFromTime(
      day['end']?.toString() ?? '',
    );

    if (start == null || end == null || end <= start) {
      return [];
    }

    return times.where((time) {
      final minutes = _minutesFromTime(time);

      return minutes != null &&
          minutes >= start &&
          minutes <= end;
    }).toList();
  }

  final List<String> times = [
    '9:00 AM',
    '10:00 AM',
    '11:00 AM',
    '12:00 PM',
    '2:00 PM',
    '3:00 PM',
    '4:00 PM',
    '5:00 PM',
  ];
// ============================================================
// CHOOSE VIEWING DATE
// ============================================================

Future<void> chooseDate() async {
  if (_scheduleLoading) return;

  if (_scheduleLoadFailed) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not load this property’s viewing schedule. Please try again.',
        ),
      ),
    );
    return;
  }

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final lastDate = today.add(const Duration(days: 90));

  bool isSelectable(DateTime date) {
    return _availableTimesForDate(date).isNotEmpty;
  }

  DateTime? firstAvailableDate;

  for (var i = 0; i <= 90; i++) {
    final candidate = today.add(Duration(days: i));

    if (isSelectable(candidate)) {
      firstAvailableDate = candidate;
      break;
    }
  }

  if (firstAvailableDate == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No viewing days or times are currently available for this property.',
        ),
      ),
    );
    return;
  }

  final previousDate = selectedDate;
  final initialDate = previousDate != null &&
          !previousDate.isBefore(today) &&
          !previousDate.isAfter(lastDate) &&
          isSelectable(previousDate)
      ? previousDate
      : firstAvailableDate;

  final date = await showDatePicker(
    context: context,
    firstDate: today,
    lastDate: lastDate,
    initialDate: initialDate,
    selectableDayPredicate: isSelectable,
  );

  if (date != null && mounted) {
    setState(() {
      selectedDate = date;

      final availableTimes = _availableTimesForDate(date);

      if (!availableTimes.contains(selectedTime)) {
        selectedTime = null;
      }
    });
  }
}
  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    messageController.dispose();
    super.dispose();
  }

Future<void> submit() async {
  final user = FirebaseAuth.instance.currentUser;

  // ------------------------------------------------------------
  // LOGIN CHECK
  // ------------------------------------------------------------

  if (user == null) {
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const AuthScreen(),
      ),
    );

    return;
  }

  // ------------------------------------------------------------
  // REQUIRED FIELD CHECK
  // ------------------------------------------------------------

  if (nameController.text.trim().isEmpty ||
      phoneController.text.trim().isEmpty ||
      selectedDate == null ||
      selectedTime == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Please complete all required fields.',
        ),
      ),
    );

    return;
  }

  // ------------------------------------------------------------
  // CHECK VIEWING AVAILABILITY
  // ------------------------------------------------------------

  try {
    final existingRequests =
        await FirebaseFirestore.instance
            .collection('viewing_requests')
            .where(
              'propertyId',
              isEqualTo: widget.property.id,
            )
            .get();

    final requestedDate = selectedDate!;

    bool timeAlreadyBooked = false;

    for (final document in existingRequests.docs) {
      final data = document.data();

      final status =
          data['status']?.toString().toLowerCase() ?? '';

      // Only pending and approved requests
      // should block the viewing slot.
      if (status != 'pending' &&
          status != 'approved') {
        continue;
      }

      final dateValue = data['date'];

      if (dateValue is! Timestamp) {
        continue;
      }

      final existingDate = dateValue.toDate();

      final sameDate =
          existingDate.year == requestedDate.year &&
          existingDate.month == requestedDate.month &&
          existingDate.day == requestedDate.day;

      final existingTime =
          data['time']?.toString() ?? '';

      final sameTime =
          existingTime == selectedTime;

      if (sameDate && sameTime) {
        timeAlreadyBooked = true;
        break;
      }
    }

    // ----------------------------------------------------------
    // SLOT NOT AVAILABLE
    // ----------------------------------------------------------

    if (timeAlreadyBooked) {
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            icon: const Icon(
              Icons.event_busy_outlined,
              color: Colors.orange,
              size: 45,
            ),
            title: const Text(
              'Viewing Time Unavailable',
              textAlign: TextAlign.center,
            ),
            content: const Text(
              'The selected viewing date and time is no longer available. '
              'Please choose another date or time and try again.',
              textAlign: TextAlign.center,
            ),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 13,
                    ),
                  ),
                  child: const Text(
                    'Choose Another Time',
                  ),
                ),
              ),
            ],
          );
        },
      );

      return;
    }

    // ------------------------------------------------------------
    // CREATE VIEWING REQUEST
    // ------------------------------------------------------------

    final request = ViewingRequest(
      property: widget.property,
      name: nameController.text.trim(),
      phone: phoneController.text.trim(),
      date: selectedDate!,
      time: selectedTime!,
      message: messageController.text.trim(),
    );

    final requestId =
        DateTime.now().millisecondsSinceEpoch.toString();

    // ============================================================
// GET PROPERTY PROVIDER INFORMATION
// ============================================================

final propertyDoc = await FirebaseFirestore.instance
    .collection('properties')
    .doc(widget.property.id)
    .get();

final propertyData = propertyDoc.data();

final ownerId =
    propertyData?['ownerId']?.toString().trim() ?? '';

final managedById =
    propertyData?['managedById']?.toString().trim() ?? '';

// Both landlord and agent will receive the same viewing request.
final providerIds = <String>{
  if (ownerId.isNotEmpty) ownerId,
  if (managedById.isNotEmpty) managedById,
}.toList();

// ============================================================
// SAVE VIEWING REQUEST
// ============================================================

await FirebaseFirestore.instance
    .collection('viewing_requests')
    .doc(requestId)
    .set({
  'id': requestId,

  // Tenant
  'tenantId': user.uid,
  'name': request.name,
  'phone': request.phone,

  // Property
  'propertyId': widget.property.id,
  'propertyTitle': widget.property.title,
  'propertyLocation': widget.property.location,

  // Property providers
  'ownerId': ownerId,
  'managedById': managedById,
  'providerIds': providerIds,

  // Requested viewing
  'date': Timestamp.fromDate(request.date),
  'time': request.time,
  'message': request.message,

  // Status
  'status': 'pending',
  'submittedAt': Timestamp.now(),
});
    ViewingRequests.add(request);

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ViewingConfirmationScreen(
          request: request,
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not check viewing availability. Please try again.',
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Request a Viewing'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (_scheduleLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: LinearProgressIndicator(),
              )
                                    else if (_scheduleLoadFailed)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Could not connect to the server to load the schedule.',
                  style: TextStyle(color: Colors.red),
                ),
              )
            else if (_viewingSchedule.isEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: const Text(
                  'This property manager has not set up viewing times yet. Please contact them directly to arrange a viewing.',
                  style: TextStyle(color: Colors.orange),
                ),
              ),
          Text(
            widget.property.title,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            widget.property.location,
            style: const TextStyle(
              color: secondaryTextColor,
            ),
          ),
          const SizedBox(height: 25),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Full name *',
              prefixIcon:
                  Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: phoneController,
            keyboardType:
                TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number *',
              prefixIcon:
                  Icon(Icons.phone_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
                    ListTile(
            enabled: _viewingSchedule.isNotEmpty,
            contentPadding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Colors.grey.shade300,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            leading: Icon(
              Icons.calendar_month,
              color: _viewingSchedule.isNotEmpty ? primaryOrange : Colors.grey,
            ),
            title: Text(
              selectedDate == null
                  ? 'Select viewing date *'
                  : '${selectedDate!.day}/${selectedDate!.month}/${selectedDate!.year}',
              style: TextStyle(
                color: _viewingSchedule.isNotEmpty ? null : Colors.grey,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: _viewingSchedule.isNotEmpty ? null : Colors.grey,
            ),
            onTap: _viewingSchedule.isNotEmpty ? chooseDate : null,
          ),
          const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
            initialValue: selectedTime,
            decoration: const InputDecoration(
              labelText: 'Preferred time *',
              prefixIcon: Icon(Icons.access_time),
              border: OutlineInputBorder(),
            ),
            items: (selectedDate == null || _viewingSchedule.isEmpty
                ? <String>[]
                : _availableTimesForDate(selectedDate!))
            .map(
              (time) => DropdownMenuItem<String>(
                value: time,
                child: Text(time),
              ),
            ).toList(),
            onChanged: _viewingSchedule.isEmpty
                ? null // 👈 Disables the dropdown if no schedule
                : (value) {
                    setState(() {
                      selectedTime = value;
                    });
                  },
          ),
          const SizedBox(height: 14),
          TextField(
            controller:
                messageController,
            maxLines: 4,
            decoration:
                const InputDecoration(
              labelText:
                  'Optional message',
              hintText:
                  'Anything you would like the manager to know?',
              border:
                  OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _scheduleLoading || _scheduleLoadFailed
              ? null
              : submit,
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    primaryOrange,
                foregroundColor:
                    Colors.white,
                padding:
                    const EdgeInsets.symmetric(
                  vertical: 16,
                ),
              ),
              child: const Text(
                'Submit Viewing Request',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// VIEWING CONFIRMATION
// ============================================================

class ViewingConfirmationScreen
    extends StatelessWidget {
  final ViewingRequest request;

  const ViewingConfirmationScreen({
    super.key,
    required this.request,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Viewing Requested'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(25),
          child: Column(
            children: [
              const CircleAvatar(
                radius: 42,
                backgroundColor:
                    availableGreen,
                child: Icon(
                  Icons.check,
                  color: Colors.white,
                  size: 45,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Viewing Request Submitted',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 25),
              _info(
                'Property',
                request.property.title,
              ),
              _info(
                'Location',
                request.property.location,
              ),
              _info(
                'Date',
                '${request.date.day}/${request.date.month}/${request.date.year}',
              ),
              _info(
                'Time',
                request.time,
              ),
              _info(
                'Name',
                request.name,
              ),
              _info(
                'Phone',
                request.phone,
              ),
              const SizedBox(height: 25),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const MainNavigationScreen(),
                      ),
                      (route) => false,
                    );
                  },
                  child:
                      const Text('Back to Home'),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const ViewingsScreen(),
                    ),
                  );
                },
                child: const Text(
                  'View My Requests',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _info(
    String title,
    String value,
  ) {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(
        vertical: 12,
      ),
      child: Row(
        children: [
          Text(
            '$title:',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// VIEWINGS SCREEN
// ============================================================
class ViewingsScreen extends StatefulWidget {
  final VoidCallback? onAccessDenied;

  const ViewingsScreen({
    super.key,
    this.onAccessDenied,
  });

  @override
  State<ViewingsScreen> createState() => _ViewingsScreenState();
}

class _ViewingsScreenState extends State<ViewingsScreen> {
  String? _tenantId;
  bool _loading = true;
  bool _isTenant = false;

  @override
  void initState() {
    super.initState();
    _loadTenant();
  }

  Future<void> _loadTenant() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        _tenantId = null;
        _isTenant = false;
        _loading = false;
      });

      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final role =
          userDoc.data()?['role']?.toString().toLowerCase() ?? '';

      if (!mounted) return;

      setState(() {
        _tenantId = user.uid;
        _isTenant = role == 'tenant';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _tenantId = user.uid;
        _isTenant = false;
        _loading = false;
      });
    }
  }

  String _formatDate(Timestamp? timestamp) {
    if (timestamp == null) {
      return 'Date not available';
    }

    final date = timestamp.toDate();

    return '${date.day}/${date.month}/${date.year}';
  }

  Widget _statusBadge(String status) {
    Color backgroundColor;
    Color textColor;
    String label;
    IconData icon;

    switch (status) {
      case 'approved':
        backgroundColor = Colors.green.shade50;
        textColor = Colors.green.shade700;
        label = 'VIEWING CONFIRMED';
        icon = Icons.check_circle;
        break;

      case 'rejected':
        backgroundColor = Colors.red.shade50;
        textColor = Colors.red.shade700;
        label = 'DECLINED';
        icon = Icons.cancel;
        break;

      default:
        backgroundColor = Colors.orange.shade50;
        textColor = Colors.orange.shade800;
        label = 'PENDING';
        icon = Icons.hourglass_top;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: textColor,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusMessage(
    String status,
    String rejectionReason,
  ) {
    if (status == 'approved') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.green.shade100,
          ),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.check_circle_outline,
              color: Colors.green,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your viewing has been confirmed by the property manager.',
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (status == 'rejected') {
      final isTimeUnavailable =
          rejectionReason.toLowerCase().contains(
                'viewing time unavailable',
              );

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.red.shade100,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.event_busy_outlined,
                  color: Colors.red,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isTimeUnavailable
                        ? 'Viewing time unavailable. The property manager is not available at the requested date/time. Please select another date or time.'
                        : rejectionReason.isNotEmpty
                            ? 'Your viewing request was declined.\n\nReason: $rejectionReason'
                            : 'Your viewing request was declined. Please select another date or time.',
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.orange.shade100,
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.hourglass_top,
            color: Colors.orange,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your viewing request is waiting for the property manager’s response.',
              style: TextStyle(
                color: Colors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmedViewingInfo(
    String dateText,
    String time,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your Viewing Details',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.calendar_month,
                color: Colors.green,
                size: 21,
              ),
              const SizedBox(width: 10),
              const Text(
                'Date',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                dateText,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.access_time,
                color: Colors.green,
                size: 21,
              ),
              const SizedBox(width: 10),
              const Text(
                'Time',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                time,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _requestCard(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();

    final propertyId =
        data['propertyId']?.toString() ?? '';

    final title =
        data['propertyTitle']?.toString() ?? 'Property';

    final location =
        data['propertyLocation']?.toString() ?? '';

    final time =
        data['time']?.toString() ?? '';

    final status =
        data['status']?.toString().toLowerCase() ?? 'pending';

    final rejectionReason =
        data['rejectionReason']?.toString() ?? '';

    final dateText = _formatDate(
      data['date'] is Timestamp
          ? data['date'] as Timestamp
          : null,
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  backgroundColor: primaryOrange,
                  child: Icon(
                    Icons.home,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        location,
                        style: const TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            _statusBadge(status),

            const SizedBox(height: 14),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_month,
                    size: 20,
                    color: primaryOrange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dateText,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.access_time,
                    size: 20,
                    color: primaryOrange,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    time,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            if (status == 'approved') ...[
              _confirmedViewingInfo(
                dateText,
                time,
              ),
              const SizedBox(height: 12),
            ],

            _statusMessage(
              status,
              rejectionReason,
            ),

            if (status == 'rejected') ...[
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: propertyId.isEmpty
                      ? null
                      : () async {
                          try {
                            final propertyDoc =
                                await FirebaseFirestore.instance
                                    .collection('properties')
                                    .doc(propertyId)
                                    .get();

                            if (!propertyDoc.exists ||
                                propertyDoc.data() == null) {
                              if (!context.mounted) return;

                              ScaffoldMessenger.of(context)
                                  .showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'This property is no longer available.',
                                  ),
                                ),
                              );

                              return;
                            }

                            final property =
                                rentalPropertyFromFirestore(
                              propertyDoc.data()!,
                            );

                            if (!context.mounted) return;

                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ViewingRequestScreen(
                                  property: property,
                                ),
                              ),
                            );
                          } catch (e) {
                            if (!context.mounted) return;

                            ScaffoldMessenger.of(context)
                                .showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not open this property. Please try again.',
                                ),
                              ),
                            );
                          }
                        },
                  icon: const Icon(
                    Icons.calendar_month,
                  ),
                  label: const Text(
                    'Choose Another Date / Time',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 13,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          color: primaryOrange,
        ),
      );
    }

    if (_tenantId == null) {
      return const Center(
        child: Text(
          'Please log in to view your viewing requests.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (!_isTenant) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onAccessDenied?.call();
      });

      return const Center(
        child: Text(
          'Tenant Access Only',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      key: ValueKey('viewings_stream_$_tenantId'),
      stream: FirebaseFirestore.instance
          .collection('viewing_requests')
          .where(
            'tenantId',
            isEqualTo: _tenantId,
          )
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(
              color: primaryOrange,
            ),
          );
        }

        if (snapshot.hasError) {
          return const Center(
            child: Text(
              'Could not load your viewing requests.',
            ),
          );
        }

        final documents =
            snapshot.data?.docs ?? [];

        if (documents.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(30),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.event_available_outlined,
                    size: 60,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 15),
                  Text(
                    'No viewing requests yet.',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'When you request a property viewing, it will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        documents.sort((a, b) {
          final aTime = a.data()['submittedAt'];
          final bTime = b.data()['submittedAt'];

          if (aTime is Timestamp &&
              bTime is Timestamp) {
            return bTime.compareTo(aTime);
          }

          return 0;
        });

        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.of(context).padding.top + 16,
            16,
            16,
          ),
          itemCount: documents.length,
          itemBuilder: (context, index) {
            return _requestCard(
              context,
              documents[index],
            );
          },
        );
      },
    );
  }
}
// ============================================================
// PROPERTY PROVIDER VIEWING REQUESTS
// Landlord and Agent can both see requests for the same property
// ============================================================

class PropertyProviderViewingsScreen
    extends StatefulWidget {
  const PropertyProviderViewingsScreen({
    super.key,
  });

  @override
  State<PropertyProviderViewingsScreen> createState() =>
      _PropertyProviderViewingsScreenState();
}

class _PropertyProviderViewingsScreenState
    extends State<PropertyProviderViewingsScreen> {
  bool isCheckingRole = true;
  bool isLandlord = false;
  bool isAgent = false;

  @override
  void initState() {
    super.initState();
    _checkRole();
  }

  // ==========================================================
  // CHECK LANDLORD / AGENT ROLE
  // ==========================================================

  Future<void> _checkRole() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
        isAgent = false;
      });

      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final role =
          userDoc.data()?['role']?.toString().trim().toLowerCase();

      if (!mounted) return;

      if (role == 'landlord' || role == 'agent') {
        setState(() {
          isCheckingRole = false;
          isLandlord = role == 'landlord';
          isAgent = role == 'agent';
        });
      } else {
        setState(() {
          isCheckingRole = false;
          isLandlord = false;
          isAgent = false;
        });
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
        isAgent = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not verify your account type.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // APPROVE VIEWING REQUEST
  // ==========================================================

  Future<void> _approveRequest(
    BuildContext context,
    String requestId,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('viewing_requests')
          .doc(requestId)
          .update({
        'status': 'approved',
        'approvedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
        'approvedAt': FieldValue.serverTimestamp(),
        'rejectionReason': FieldValue.delete(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Viewing request approved.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not approve this viewing request.',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // REJECT VIEWING REQUEST
  // ==========================================================

  Future<void> _rejectRequest(
  BuildContext context,
  String requestId,
) async {
  String selectedReason = 'Viewing time unavailable';
  final additionalReasonController =
      TextEditingController();

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (
          context,
          setDialogState,
        ) {
          return AlertDialog(
            title: const Text(
              'Decline Viewing Request',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Please select the reason for declining this viewing request.',
                  ),

                  const SizedBox(height: 16),

                  DropdownButtonFormField<String>(
                    initialValue: selectedReason,
                    decoration: const InputDecoration(
                      labelText: 'Reason',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value:
                            'Viewing time unavailable',
                        child: Text(
                          'Viewing time unavailable',
                        ),
                      ),
                      DropdownMenuItem(
                        value:
                            'Property manager unavailable',
                        child: Text(
                          'Property manager unavailable',
                        ),
                      ),
                      DropdownMenuItem(
                        value:
                            'Property unavailable on this date',
                        child: Text(
                          'Property unavailable on this date',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'Other',
                        child: Text('Other'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;

                      setDialogState(() {
                        selectedReason = value;
                      });
                    },
                  ),

                  const SizedBox(height: 14),

                  TextField(
                    controller:
                        additionalReasonController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText:
                          'Additional explanation (optional)',
                      hintText:
                          'Add more information for the tenant...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (selectedReason == 'Other' &&
                      additionalReasonController.text
                          .trim()
                          .isEmpty) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please provide a reason.',
                        ),
                      ),
                    );
                    return;
                  }

                  String finalReason =
                      selectedReason;

                  final additional =
                      additionalReasonController
                          .text
                          .trim();

                  if (additional.isNotEmpty) {
                    finalReason =
                        '$selectedReason — $additional';
                  }

                  Navigator.pop(
                    dialogContext,
                    finalReason,
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Decline Request'),
              ),
            ],
          );
        },
      );
    },
  );

  additionalReasonController.dispose();

  if (result == null || result.trim().isEmpty) {
    return;
  }

  try {
    await FirebaseFirestore.instance
        .collection('viewing_requests')
        .doc(requestId)
        .update({
      'status': 'rejected',
      'rejectedBy':
          FirebaseAuth.instance.currentUser?.uid ?? '',
      'rejectedAt':
          FieldValue.serverTimestamp(),
      'rejectionReason': result.trim(),
      'approvedAt': FieldValue.delete(),
      'approvedBy': FieldValue.delete(),
    });

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Viewing request declined.',
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not decline this viewing request.',
        ),
      ),
    );
  }
}

  // ==========================================================
  // VIEWING REQUEST CARD
  // ==========================================================

  Widget _requestCard(
    BuildContext context,
    String requestId,
    Map<String, dynamic> data,
  ) {
    final propertyTitle =
        data['propertyTitle']?.toString() ??
            'Rental Property';

    final propertyLocation =
        data['propertyLocation']?.toString() ??
            '';

    final tenantName =
        data['name']?.toString() ??
            'Tenant';

    final tenantPhone =
        data['phone']?.toString() ??
            '';

    final requestedTime =
        data['time']?.toString() ??
            '';

    final tenantMessage =
        data['message']?.toString() ??
            '';

    final status =
        data['status']?.toString() ??
            'pending';

    final dateValue = data['date'];

    DateTime? viewingDate;

    if (dateValue is Timestamp) {
      viewingDate = dateValue.toDate();
    }

    final dateText = viewingDate == null
        ? 'Date not available'
        : '${viewingDate.day}/'
            '${viewingDate.month}/'
            '${viewingDate.year}';

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (status == 'approved') {
      statusColor = availableGreen;
      statusText = 'APPROVED';
      statusIcon =
          Icons.check_circle_outline;
    } else if (status == 'rejected') {
      statusColor = Colors.red;
      statusText = 'REJECTED';
      statusIcon =
          Icons.cancel_outlined;
    } else {
      statusColor = Colors.orange;
      statusText = 'PENDING';
      statusIcon =
          Icons.pending_outlined;
    }

    return Card(
      margin: const EdgeInsets.only(
        bottom: 14,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            // --------------------------------------------------
            // PROPERTY
            // --------------------------------------------------

            Text(
              propertyTitle,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            if (propertyLocation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                propertyLocation,
                style: const TextStyle(
                  color: secondaryTextColor,
                ),
              ),
            ],

            const SizedBox(height: 14),

            // --------------------------------------------------
            // STATUS
            // --------------------------------------------------

            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(
                vertical: 11,
                horizontal: 12,
              ),
              decoration: BoxDecoration(
                color: statusColor.withValues(
                  alpha: 0.07,
                ),
                borderRadius:
                    BorderRadius.circular(10),
                border: Border.all(
                  color: statusColor.withValues(
                    alpha: 0.25,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    statusIcon,
                    color: statusColor,
                    size: 21,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // --------------------------------------------------
            // TENANT DETAILS
            // --------------------------------------------------

            const Text(
              'Tenant',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(
                  Icons.person_outline,
                  size: 20,
                  color: primaryOrange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(tenantName),
                ),
              ],
            ),

            if (tenantPhone.isNotEmpty) ...[
              const SizedBox(height: 7),
              Row(
                children: [
                  const Icon(
                    Icons.phone_outlined,
                    size: 20,
                    color: primaryOrange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tenantPhone),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),

            // --------------------------------------------------
            // REQUESTED VIEWING
            // --------------------------------------------------

            const Text(
              'Requested Viewing',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(
                  Icons.calendar_month_outlined,
                  size: 20,
                  color: primaryOrange,
                ),
                const SizedBox(width: 8),
                Text(dateText),
              ],
            ),

            const SizedBox(height: 7),

            Row(
              children: [
                const Icon(
                  Icons.access_time,
                  size: 20,
                  color: primaryOrange,
                ),
                const SizedBox(width: 8),
                Text(
                  requestedTime.isEmpty
                      ? 'Time not available'
                      : requestedTime,
                ),
              ],
            ),

            // --------------------------------------------------
            // TENANT MESSAGE
            // --------------------------------------------------

            if (tenantMessage.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Tenant Message',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 7),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius:
                      BorderRadius.circular(10),
                ),
                child: Text(
                  tenantMessage,
                  style: const TextStyle(
                    color: secondaryTextColor,
                  ),
                ),
              ),
            ],

            // --------------------------------------------------
            // ACTIONS
            // --------------------------------------------------

            if (status == 'pending') ...[
              const SizedBox(height: 18),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _rejectRequest(
                          context,
                          requestId,
                        );
                      },
                      icon: const Icon(
                        Icons.close,
                      ),
                      label: const Text(
                        'Reject',
                      ),
                      style:
                          OutlinedButton.styleFrom(
                        foregroundColor:
                            Colors.red,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        _approveRequest(
                          context,
                          requestId,
                        );
                      },
                      icon: const Icon(
                        Icons.check,
                      ),
                      label: const Text(
                        'Approve',
                      ),
                      style:
                          ElevatedButton.styleFrom(
                        backgroundColor:
                            availableGreen,
                        foregroundColor:
                            Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // --------------------------------------------------
            // REJECTION REASON
            // --------------------------------------------------

            if (status == 'rejected') ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(
                    alpha: 0.06,
                  ),
                  borderRadius:
                      BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.red.withValues(
                      alpha: 0.20,
                    ),
                  ),
                ),
                child: Text(
                  'Rejection reason: '
                  '${data['rejectionReason']?.toString() ?? 'No reason provided.'}',
                  style: const TextStyle(
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    if (isCheckingRole) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Viewing Requests',
          ),
        ),
        body: const Center(
          child: CircularProgressIndicator(
            color: primaryOrange,
          ),
        ),
      );
    }

    if (!isLandlord && !isAgent) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Viewing Requests',
          ),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(25),
            child: Text(
              'Landlord or Agent access required.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: 16,
              ),
            ),
          ),
        ),
      );
    }

    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Viewing Requests',
          ),
        ),
        body: const Center(
          child: Text(
            'Please log in to continue.',
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Viewing Requests',
        ),
      ),
      body: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('viewing_requests')
            .where(
              'providerIds',
              arrayContains: user.uid,
            )
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(25),
                child: Text(
                  'Could not load viewing requests.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          if (documents.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(25),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_month_outlined,
                      size: 70,
                      color: Colors.grey,
                    ),
                    SizedBox(height: 15),
                    Text(
                      'No viewing requests yet',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Tenant viewing requests for your properties will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryTextColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: documents.length,
            itemBuilder: (context, index) {
              final document =
                  documents[index];

              return _requestCard(
                context,
                document.id,
                document.data(),
              );
            },
          );
        },
      ),
    );
  }
}
// ============================================================
// SAVED SCREEN
// ============================================================

class SavedScreen extends StatefulWidget {
  const SavedScreen({
    super.key,
    this.onAccessDenied,
  });

  final VoidCallback? onAccessDenied;

  @override
  State<SavedScreen> createState() =>
      _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  bool isCheckingRole = true;
  bool isTenant = false;

  String? currentUserId;

  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();

    currentUserId =
        FirebaseAuth.instance.currentUser?.uid;

    _checkTenantRole();

    _authSubscription =
        FirebaseAuth.instance.authStateChanges().listen(
      (user) {
        final newUserId = user?.uid;

        // Nothing changed.
        if (newUserId == currentUserId) {
          return;
        }

        currentUserId = newUserId;

        if (!mounted) return;

        // IMPORTANT:
        // Clear the previous account's saved homes.
        SavedProperties.savedIds.value = {};

        // Reset the role state for the new account.
        setState(() {
          isCheckingRole = true;
          isTenant = false;
        });

        _checkTenantRole();
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkTenantRole() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isTenant = false;
      });

      return;
    }

    // Remember which account started this check.
    final checkingUserId = user.uid;

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      // IMPORTANT:
      // If the account changed while Firestore was loading,
      // ignore the old account's result.
      if (FirebaseAuth.instance.currentUser?.uid !=
          checkingUserId) {
        return;
      }

      final data = userDoc.data();

      final role =
          data?['role']?.toString().trim().toLowerCase();

      debugPrint(
        'CURRENT USER UID: ${user.uid}',
      );

      debugPrint(
        'USER DOCUMENT EXISTS: ${userDoc.exists}',
      );

      debugPrint(
        'USER DOCUMENT DATA: $data',
      );

      debugPrint(
        'USER ROLE: $role',
      );

      if (!mounted) return;

      if (role == 'tenant') {
        setState(() {
          isCheckingRole = false;
          isTenant = true;
        });
      } else {
        setState(() {
          isCheckingRole = false;
          isTenant = false;
        });

        _showAccessDenied();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isTenant = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not verify your account type. Please try again.',
          ),
        ),
      );
    }
  }

  void _showAccessDenied() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            icon: const Icon(
              Icons.lock_outline,
              color: primaryOrange,
              size: 42,
            ),
            title: const Text(
              'Tenant Access Only',
            ),
            content: const Text(
              'Saved Homes is available only to tenant accounts.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
  Navigator.pop(dialogContext);

  widget.onAccessDenied?.call();
},
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryOrange,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'Go Back',
                ),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isCheckingRole) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Saved Homes',
          ),
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: primaryOrange,
              ),
              SizedBox(height: 16),
              Text(
                'Checking your account...',
                style: TextStyle(
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!isTenant) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Saved Homes',
          ),
        ),
        body: const Center(
          child: Text(
            'Tenant access required.',
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'Saved Homes',
          ),
        ),
        body: const Center(
          child: Text(
            'Please log in to view saved homes.',
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    final tenantId = user.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Saved Homes',
        ),
      ),
      body: ValueListenableBuilder<Set<String>>(
        valueListenable: SavedProperties.savedIds,
        builder: (
          context,
          savedIds,
          _,
        ) {
          if (savedIds.isEmpty) {
            return _emptyState();
          }

          return StreamBuilder<
              QuerySnapshot<Map<String, dynamic>>>(
            key: ValueKey(
              'saved_homes_$tenantId',
            ),
           stream: FirebaseFirestore.instance
            .collection('properties')
            .where(
              'status',
              isEqualTo: 'approved',
            )
            .where(
              'verified',
              isEqualTo: true,
            )
            .snapshots(),
            builder: (
              context,
              snapshot,
            ) {
              if (snapshot.connectionState ==
                  ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              if (snapshot.hasError) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(30),
                    child: Text(
                      'Could not load saved homes.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              final documents =
                  snapshot.data?.docs ?? [];

              final savedProperties = documents
                  .map(
                    (doc) =>
                        rentalPropertyFromFirestore(
                      doc.data(),
                    ),
                  )
                  .where(
                    (property) =>
                        savedIds.contains(
                      property.id,
                    ),
                  )
                  .toList();

              if (savedProperties.isEmpty) {
                return _emptyState();
              }

              return ListView(
                padding: const EdgeInsets.all(16),
                children: savedProperties
                    .map(
                      (property) => PropertyCard(
                        property: property,
                      ),
                    )
                    .toList(),
              );
            },
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border,
              size: 75,
              color: Colors.grey,
            ),
            SizedBox(height: 15),
            Text(
              'No saved homes yet',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the heart on a property to save it here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LANDLORD DASHBOARD
// ============================================================

class LandlordDashboardScreen extends StatefulWidget {
  const LandlordDashboardScreen({super.key});

  @override
  State<LandlordDashboardScreen> createState() =>
      _LandlordDashboardScreenState();
}

class _LandlordDashboardScreenState
    extends State<LandlordDashboardScreen> {
  bool isCheckingRole = true;
bool isLandlord = false;
bool isAgent = false;

  @override
  void initState() {
    super.initState();
    _checkLandlordRole();
  }

  Future<void> _checkLandlordRole() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
      });

      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final data = userDoc.data();

      final role = data?['role']?.toString().toLowerCase();

      if (!mounted) return;

      if (role == 'landlord' ||
    role == 'agent') {
  setState(() {
    isCheckingRole = false;
    isLandlord = role == 'landlord';
    isAgent = role == 'agent';
  });
} else { 
        setState(() {
          isCheckingRole = false;
          isLandlord = false;
        });

        _showAccessDenied();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not verify your account type. Please try again.',
          ),
        ),
      );
    }
  }

  void _showAccessDenied() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            icon: const Icon(
              Icons.lock_outline,
              color: primaryOrange,
              size: 42,
            ),
            title: const Text(
              'Landlord Access Only',
            ),
            content: const Text(
              'This section is available only to landlord accounts. '
              'Your current account is not registered as a landlord.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);

                  if (mounted) {
                    Navigator.pop(context);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryOrange,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'Go Back',
                ),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isCheckingRole) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Property Provider Dashboard'),
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: primaryOrange,
              ),
              SizedBox(height: 16),
              Text(
                'Checking your account...',
                style: TextStyle(
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!isLandlord && !isAgent) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Property Provider Dashboard'),
        ),
        body: const Center(
          child: Text(
            'Property provider access required.',
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Property Provider Dashboard'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  primaryOrange,
                  darkOrange,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.home_work,
                  color: Colors.white,
                  size: 40,
                ),
                SizedBox(height: 15),
                Text(
                  'Manage Your Properties',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'List, manage and keep track of rental properties on KejaFind.',
                  style: TextStyle(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          _dashboardButton(
            context,
            Icons.add_home_work_outlined,
            'Add Property',
            'Create a new rental listing',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const AddPropertyScreen(),
                ),
              );
            },
          ),

          const SizedBox(height: 12),

          _dashboardButton(
            context,
            Icons.list_alt,
            'My Listings',
            'View and manage properties you have listed',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const MyListingsScreen(),
                ),
              );
            },
          ),
           const SizedBox(height: 12),

              _dashboardButton(
                context,
                Icons.calendar_month_outlined,
                'Viewings',
                'View and manage tenant viewing requests',
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PropertyProviderViewingsScreen(),
                    ),
                  );
                },
              ),
          // ============================================================
          // OWNER REQUESTS — AGENT ONLY
          // ============================================================

          if (isAgent) ...[
            const SizedBox(height: 12),

            _dashboardButton(
              context,
              Icons.handshake_outlined,
              'Owner Requests',
              'Track properties you are listing for owners',
              () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const AgentOwnerRequestsScreen(),
                  ),
                );
              },
            ),
          ],
          // ============================================================
// AGENT REQUESTS — LANDLORD ONLY
// ============================================================

if (isLandlord) ...[
  const SizedBox(height: 12),

  _dashboardButton(
    context,
    Icons.handshake_outlined,
    'Agent Requests',
    'Review requests from agents to manage your properties',
    () {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              const OwnerAgentRequestsScreen(),
        ),
      );
    },
  ),
],
        ],
      ),
    );
  }

  Widget _dashboardButton(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(15),
        leading: CircleAvatar(
          backgroundColor:
              primaryOrange.withOpacity(0.12),
          child: Icon(
            icon,
            color: primaryOrange,
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(
          Icons.arrow_forward_ios,
          size: 18,
        ),
        onTap: onTap,
      ),
    );
  }
}
// ============================================================
// ADD PROPERTY SCREEN
// ============================================================

class AddPropertyScreen extends StatefulWidget {
  const AddPropertyScreen({super.key});

  @override
  State<AddPropertyScreen> createState() =>
      _AddPropertyScreenState();
}

class _AddPropertyScreenState
    extends State<AddPropertyScreen> {
  final titleController = TextEditingController();
  final locationController = TextEditingController();
  final rentController = TextEditingController();
  final sizeController = TextEditingController();
  final descriptionController = TextEditingController();
  // ============================================================
// OWNER DETAILS — FOR AGENT LISTINGS
// ============================================================

final ownerNameController = TextEditingController();
final ownerPhoneController = TextEditingController();
final ownerEmailController = TextEditingController();

  String selectedPropertyType = 'Apartment';
  String selectedPropertySetting = 'Apartment Block';
  String selectedBedrooms = 'Bedsitter';
  String selectedBathrooms = '1';
  String selectedAvailability = 'Available now';
   DateTime? selectedAvailableFrom;

  final Set<String> selectedAmenities = {};

  final ImagePicker imagePicker = ImagePicker();

  List<XFile> selectedPhotos = [];
  String? mainPhotoPath;

  final Map<String, List<XFile>> categorizedPhotos = {
    'Front View': [],
    'Living Room': [],
    'Bedroom': [],
    'Shower Area': [],
    'Kitchen': [],
    'Balcony': [],
    'Parking Area': [],
  };

  bool isSubmitting = false;

String currentUserRole = 'landlord';
bool isLoadingRole = true;

bool isAgent = false;

bool listingForOwner = false;
String? agentListingChoice;
double uploadProgress = 0.0;
int uploadedPhotoCount = 0;
int totalPhotoCount = 0;
String uploadingCategory = '';

  String? selectedCounty;
  String? selectedCity;
  String? selectedArea;

  final List<String> propertyTypeOptions = [
  'Apartment',
  'Standalone House',
  'Maisonette',
  'Townhouse',
  'Villa',
  'Gated Community',
  'Serviced Apartment',
  'Studio / Bedsitter',
  'Other',
];
final List<String> propertySettingOptions = [
  'Apartment Block',
  'Standalone / Own Compound',
  'Gated Community',
  'Shared Compound',
  'Other',
];

  final List<String> bedroomOptions = [
    'Bedsitter',
    '1',
    '2',
    '3',
    '4+',
  ];

  final List<String> bathroomOptions = [
    '1',
    '2',
    '3',
    '4+',
  ];

  final List<String> availabilityOptions = [
    'Available now',
    'Available this month',
    'Available next month',
  ];

  final List<String> amenityOptions = [
    'Parking',
    'Security',
    'Water',
    'Lift',
    'Internet',
    'Generator',
    'Swimming Pool',
    'CCTV',
    'Balcony',
    'Furnished',
  ];

  List<String> get countyOptions {
    return kenyaLocations
        .map((location) => location.county)
        .toSet()
        .toList();
  }

  List<String> get cityOptions {
    if (selectedCounty == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county == selectedCounty,
        )
        .map((location) => location.city)
        .toSet()
        .toList();
  }

  List<String> get areaOptions {
    if (selectedCounty == null ||
        selectedCity == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county == selectedCounty &&
              location.city == selectedCity,
        )
        .map((location) => location.area)
        .toSet()
        .toList();
  }

// ============================================================
// LOAD CURRENT USER ROLE
// ============================================================

@override
void initState() {
  super.initState();
  _checkLandlordRole();
}

Future<void> _checkLandlordRole() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    if (!mounted) return;

    setState(() {
      isLoadingRole = false;
      currentUserRole = 'tenant';
      isAgent = false;
    });

    return;
  }

  try {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final data = userDoc.data();

    final role =
        data?['role']?.toString().toLowerCase();

    if (!mounted) return;

    if (role == 'landlord' || role == 'agent') {
  setState(() {
    isLoadingRole = false;
    currentUserRole = role!;
    isAgent = role == 'agent';
  });

  // Show the agent choice after the screen is ready.
  if (role == 'agent') {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _showAgentListingChoice();
    });
  }
} else {
      setState(() {
        isLoadingRole = false;
        currentUserRole = 'tenant';
        isAgent = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only landlord and agent accounts can add properties.',
          ),
        ),
      );
    }
  } catch (e) {
    if (!mounted) return;

    setState(() {
      isLoadingRole = false;
      isAgent = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not verify your account type. Please try again.',
        ),
      ),
    );
  }
}
// ============================================================
// AGENT LISTING CHOICE POPUP
// ============================================================

void _showAgentListingChoice() {
  agentListingChoice = null;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'Who are you listing this property for?',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Please choose how you are listing this property.',
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 14,
                  ),
                ),

                const SizedBox(height: 18),

                // MY OWN PROPERTY
                GestureDetector(
                  onTap: () {
                    setDialogState(() {
                      agentListingChoice = 'own';
                    });

                    setState(() {
                      listingForOwner = false;
                    });
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: agentListingChoice == 'own'
                          ? const Color(0xFFFFF3E6)
                          : Colors.white,
                      borderRadius:
                          BorderRadius.circular(14),
                      border: Border.all(
                        color: agentListingChoice == 'own'
                            ? primaryOrange
                            : Colors.grey.shade300,
                        width:
                            agentListingChoice == 'own'
                                ? 2
                                : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.home_work_outlined,
                          color:
                              agentListingChoice == 'own'
                                  ? primaryOrange
                                  : secondaryTextColor,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                'My own property',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'I own this property.',
                                style: TextStyle(
                                  color:
                                      secondaryTextColor,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (agentListingChoice == 'own')
                          const Icon(
                            Icons.check_circle,
                            color: primaryOrange,
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // ON BEHALF OF OWNER
                GestureDetector(
                  onTap: () {
                    setDialogState(() {
                      agentListingChoice = 'owner';
                    });

                    setState(() {
                      listingForOwner = true;
                    });
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: agentListingChoice == 'owner'
                          ? const Color(0xFFFFF3E6)
                          : Colors.white,
                      borderRadius:
                          BorderRadius.circular(14),
                      border: Border.all(
                        color: agentListingChoice == 'owner'
                            ? primaryOrange
                            : Colors.grey.shade300,
                        width:
                            agentListingChoice == 'owner'
                                ? 2
                                : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          color:
                              agentListingChoice == 'owner'
                                  ? primaryOrange
                                  : secondaryTextColor,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                'On behalf of an owner',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'I manage this property for an owner.',
                                style: TextStyle(
                                  color:
                                      secondaryTextColor,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (agentListingChoice == 'owner')
                          const Icon(
                            Icons.check_circle,
                            color: primaryOrange,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actionsPadding:
                const EdgeInsets.fromLTRB(20, 0, 20, 18),
            actions: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: agentListingChoice == null
                      ? null
                      : () {
                          Navigator.pop(dialogContext);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryOrange,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        Colors.grey.shade300,
                    disabledForegroundColor:
                        Colors.grey.shade600,
                    minimumSize:
                        const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
Future<void> addPhotosToCategory(String category) async {
  try {
    final List<XFile> photos =
        await imagePicker.pickMultiImage(
      imageQuality: 80,
      maxWidth: 1200,
      maxHeight: 1200,
    );

    if (photos.isEmpty) return;

    setState(() {
      categorizedPhotos[category] = [
        ...categorizedPhotos[category]!,
        ...photos,
      ];

      selectedPhotos = [
        ...selectedPhotos,
        ...photos,
      ];
    });

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${photos.length} photo${photos.length == 1 ? '' : 's'} added to $category.',
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not select photos. Please try again.',
        ),
      ),
    );
  }
}
 Future<List<String>> uploadPropertyPhotos(
  String propertyId,
) async {
  final List<String> downloadUrls = [];

  totalPhotoCount = selectedPhotos.length;
  uploadedPhotoCount = 0;
  uploadProgress = 0.0;
  uploadingCategory = '';

  for (final entry in categorizedPhotos.entries) {
    final category = entry.key;
    final photos = entry.value;

    if (photos.isEmpty) {
      continue;
    }

    uploadingCategory = category;

    for (int i = 0; i < photos.length; i++) {
      final photo = photos[i];

      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${i}_${photo.name}';

      final storageRef = FirebaseStorage.instance
          .ref()
          .child('properties')
          .child(propertyId)
          .child(category)
          .child(fileName);

      final bytes = await photo.readAsBytes();

      final metadata = SettableMetadata(
        contentType: photo.mimeType ?? 'image/jpeg',
      );
        debugPrint('--- BYTES READ, STARTING NETWORK UPLOAD ---');

      final uploadTask = storageRef.putData(
        bytes,
        metadata,
      );

      // Listen to the real Firebase upload progress.
      await for (final snapshot in uploadTask.snapshotEvents) {
        if (!mounted) return downloadUrls;

        final totalBytes = snapshot.totalBytes;

        if (totalBytes > 0) {
          final currentPhotoProgress =
              snapshot.bytesTransferred / totalBytes;

          setState(() {
            uploadProgress =
                (uploadedPhotoCount + currentPhotoProgress) /
                    totalPhotoCount;
          });
        }
      }

      final downloadUrl =
          await storageRef.getDownloadURL();

      downloadUrls.add(downloadUrl);

      uploadedPhotoCount++;

      if (mounted) {
        setState(() {
          uploadProgress =
              uploadedPhotoCount / totalPhotoCount;
        });
      }
    }
  }

  if (mounted) {
    setState(() {
      uploadProgress = 1.0;
      uploadingCategory = 'Complete';
    });
  }

  return downloadUrls;
}
  void removeCategoryPhoto(
    String category,
    int index,
  ) {
    final photo = categorizedPhotos[category]![index];

    setState(() {
      categorizedPhotos[category]!.removeAt(index);

      selectedPhotos.removeWhere(
        (item) => item.path == photo.path,
      );
    });
  }

  void openFullScreenViewer(
    String category,
    int initialIndex,
  ) {
    final photos = categorizedPhotos[category]!;

    if (photos.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _PhotoFullScreenViewer(
          photos: photos,
          initialIndex: initialIndex,
          category: category,
          mainPhotoPath: mainPhotoPath,
          onSetMainPhoto: (photoPath) {
            setState(() {
              mainPhotoPath = photoPath;
            });
          },
        ),
      ),
    );
  }
  Widget _buildLandlordLocationSelector() {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: primaryOrange.withOpacity(0.18),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: primaryOrange.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on_rounded,
                color: primaryOrange,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Property Location',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  SizedBox(height: 3),
                  Text(
                    'Help tenants find your property easily',
                    style: TextStyle(
                      fontSize: 13,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        _buildLandlordLocationOption(
          icon: Icons.map_outlined,
          title: 'County',
          value: selectedCounty ?? 'Select county',
          enabled: true,
          onTap: () {
            _showLandlordLocationPicker(
              title: 'Select County',
              items: countyOptions,
              selectedValue: selectedCounty,
              onSelected: (value) {
                setState(() {
                  selectedCounty = value;
                  selectedCity = null;
                  selectedArea = null;
                });
              },
            );
          },
        ),

        const SizedBox(height: 8),

        _buildLandlordLocationOption(
          icon: Icons.location_city_outlined,
          title: 'City / Town',
          value: selectedCity ?? 'Select city or town',
          enabled: selectedCounty != null,
          onTap: selectedCounty == null
              ? null
              : () {
                  _showLandlordLocationPicker(
                    title: 'Select City / Town',
                    items: cityOptions,
                    selectedValue: selectedCity,
                    onSelected: (value) {
                      setState(() {
                        selectedCity = value;
                        selectedArea = null;
                      });
                    },
                  );
                },
        ),

        const SizedBox(height: 8),

        _buildLandlordLocationOption(
          icon: Icons.place_outlined,
          title: 'Area / Estate',
          value: selectedArea ?? 'Select area or estate',
          enabled: selectedCity != null,
          onTap: selectedCity == null
              ? null
              : () {
                  _showLandlordLocationPicker(
                    title: 'Select Area / Estate',
                    items: areaOptions,
                    selectedValue: selectedArea,
                    onSelected: (value) {
                      setState(() {
                        selectedArea = value;
                      });
                    },
                  );
                },
        ),

        if (selectedCounty != null ||
            selectedCity != null ||
            selectedArea != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                Icons.check_circle,
                size: 17,
                color: availableGreen,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  [
                    if (selectedCounty != null)
                      selectedCounty!,
                    if (selectedCity != null)
                      selectedCity!,
                    if (selectedArea != null)
                      selectedArea!,
                  ].join(' • '),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: availableGreen,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    selectedCounty = null;
                    selectedCity = null;
                    selectedArea = null;
                  });
                },
                child: const Text(
                  'Clear',
                  style: TextStyle(
                    color: primaryOrange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
Widget _buildLandlordLocationOption({
  required IconData icon,
  required String title,
  required String value,
  required bool enabled,
  required VoidCallback? onTap,
}) {
  final bool hasValue =
      value != 'Select county' &&
      value != 'Select city or town' &&
      value != 'Select area or estate';

  return Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFFFFF8F2)
              : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: enabled
                ? primaryOrange.withOpacity(0.12)
                : Colors.grey.withOpacity(0.12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 22,
              color: enabled
                  ? primaryOrange
                  : Colors.grey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      color: enabled
                          ? secondaryTextColor
                          : Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: hasValue
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: enabled
                          ? (hasValue
                              ? textColor
                              : secondaryTextColor)
                          : Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: enabled
                  ? secondaryTextColor
                  : Colors.grey.shade400,
            ),
          ],
        ),
      ),
    ),
  );
}
void _showLandlordLocationPicker({
  required String title,
  required List<String> items,
  required String? selectedValue,
  required ValueChanged<String> onSelected,
}) {
  final TextEditingController searchController =
      TextEditingController();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final searchText =
              searchController.text.trim().toLowerCase();

          final filteredItems = items.where((item) {
            return item.toLowerCase().contains(searchText);
          }).toList();

          return Container(
            height:
                MediaQuery.of(context).size.height * 0.72,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),

                Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius:
                        BorderRadius.circular(10),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    20,
                    18,
                    20,
                    10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.location_on_outlined,
                          color: primaryOrange,
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                      ),

                      IconButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        icon: const Icon(
                          Icons.close_rounded,
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                  ),
                  child: TextField(
                    controller: searchController,
                    onChanged: (_) {
                      setSheetState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: 'Search $title...',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                      ),
                      suffixIcon:
                          searchController.text.isNotEmpty
                              ? IconButton(
                                  onPressed: () {
                                    searchController.clear();
                                    setSheetState(() {});
                                  },
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                  ),
                                )
                              : null,
                      filled: true,
                      fillColor: const Color(0xFFF7F7F7),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                Expanded(
                  child: filteredItems.isEmpty
                      ? const Center(
                          child: Text(
                            'No locations found',
                            style: TextStyle(
                              color: secondaryTextColor,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding:
                              const EdgeInsets.fromLTRB(
                            12,
                            4,
                            12,
                            20,
                          ),
                          itemCount:
                              filteredItems.length,
                          itemBuilder:
                              (context, index) {
                            final item =
                                filteredItems[index];

                            final isSelected =
                                item == selectedValue;

                            return ListTile(
                              shape:
                                  RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(
                                  12,
                                ),
                              ),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? primaryOrange
                                          .withOpacity(
                                          0.12,
                                        )
                                      : Colors.grey
                                          .withOpacity(
                                          0.08,
                                        ),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.location_on_outlined,
                                  size: 20,
                                  color: isSelected
                                      ? primaryOrange
                                      : secondaryTextColor,
                                ),
                              ),
                              title: Text(
                                item,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                ),
                              ),
                              trailing: isSelected
                                  ? const Icon(
                                      Icons.check_circle,
                                      color:
                                          primaryOrange,
                                    )
                                  : const Icon(
                                      Icons
                                          .chevron_right_rounded,
                                      color:
                                          Colors.grey,
                                    ),
                              onTap: () {
                                onSelected(item);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

 Future<void> submitProperty() async {
  if (titleController.text.trim().isEmpty ||
      selectedCounty == null ||
      selectedCity == null ||
      selectedArea == null ||
      rentController.text.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Please enter property title, location and rent.',
        ),
      ),
    );
    return;
  }

  final rent = int.tryParse(
    rentController.text.replaceAll(',', '').trim(),
  );

  if (rent == null || rent <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Please enter a valid monthly rent.',
        ),
      ),
    );
    return;
  }

  final size = int.tryParse(
        sizeController.text.trim(),
      ) ??
      0;

  int bedrooms = 0;

  if (selectedBedrooms == '1') {
    bedrooms = 1;
  } else if (selectedBedrooms == '2') {
    bedrooms = 2;
  } else if (selectedBedrooms == '3') {
    bedrooms = 3;
  } else if (selectedBedrooms == '4+') {
    bedrooms = 4;
  }

  int bathrooms = int.tryParse(selectedBathrooms) ?? 1;

  if (selectedBathrooms == '4+') {
    bathrooms = 4;
  }

  // ============================================================
  // VALIDATE OWNER DETAILS FOR AGENT LISTINGS
  // ============================================================

  if (isAgent && listingForOwner) {
    if (ownerNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter the property owner\'s full name.',
          ),
        ),
      );
      return;
    }

    // Validate Kenyan owner phone number.
    final ownerPhone =
        ownerPhoneController.text.trim().replaceAll(' ', '');

    final kenyaPhoneRegex = RegExp(
      r'^(?:07\d{8}|01\d{8}|\+2547\d{8}|\+2541\d{8})$',
    );

    if (!kenyaPhoneRegex.hasMatch(ownerPhone)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter a valid Kenyan phone number.',
          ),
        ),
      );
      return;
    }

    // Validate owner email.
    final ownerEmail =
        ownerEmailController.text.trim();

    if (ownerEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter the property owner\'s email address.',
          ),
        ),
      );
      return;
    }

    final emailRegex = RegExp(
      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
    );

    if (!emailRegex.hasMatch(ownerEmail)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter a valid owner email address.',
          ),
        ),
      );
      return;
    }
  }

  // ============================================================
  // RESOLVE THE EFFECTIVE OWNER UID
  // ============================================================
  //
  // When an agent lists a property on behalf of an owner, the
  // 'ownerId' stored on the property document must be the
  // OWNER'S uid — not the agent's uid. This is required by the
  // Firestore security rules, which forbid changing 'ownerId'
  // after the document is created.
  //
  // We look up the owner's RentalApp account by email. If no
  // account exists yet, we fall back to the agent's uid and the
  // owner-representation request remains pending. The admin can
  // then complete verification once the owner registers.

    // ============================================================
  // RESOLVE THE EFFECTIVE OWNER UID
  // ============================================================

  String? resolvedOwnerUid;

  if (isAgent && listingForOwner) {
    final ownerEmailLookup =
        ownerEmailController.text.trim().toLowerCase();

    final ownerQuery = await FirebaseFirestore.instance
        .collection('users')
        .where('email', isEqualTo: ownerEmailLookup)
        .where('role', isEqualTo: 'landlord')
        .limit(1)
        .get();

    if (ownerQuery.docs.isNotEmpty) {
      resolvedOwnerUid = ownerQuery.docs.first.id;
    }
  }

  // If the owner is registered, use their UID.
  // If they aren't, use the Agent's UID as a temporary placeholder.
  final effectiveOwnerId =
      (isAgent && listingForOwner && resolvedOwnerUid != null)
          ? resolvedOwnerUid
          : FirebaseAuth.instance.currentUser!.uid;

  final listingId =
      DateTime.now().millisecondsSinceEpoch.toString();

  final submittedAt = DateTime.now();

  final listing = LandlordListing(
    id: listingId,
    ownerId: effectiveOwnerId,
    managedById: FirebaseAuth.instance.currentUser!.uid,
    title: titleController.text.trim(),
    location: '$selectedArea, $selectedCity',
    propertyType: selectedPropertyType,
    propertySetting: selectedPropertySetting,
    rent: rent,
    bedrooms: bedrooms,
    bathrooms: bathrooms,
    size: size,
    availability: selectedAvailability,
    availableFrom: selectedAvailableFrom,
    description: descriptionController.text.trim(),
    amenities: selectedAmenities.toList(),
    submittedAt: submittedAt,
    photoPaths:
        selectedPhotos.map((photo) => photo.path).toList(),
  );

  setState(() {
    isSubmitting = true;
  });

  try {
    debugPrint('--- UPLOAD FUNCTION STARTED ---');

    // Upload all selected photos to Firebase Storage.
    final List<String> photoDownloadUrls =
        await uploadPropertyPhotos(listing.id);

    debugPrint('--- PHOTO UPLOAD COMPLETE, SAVING PROPERTY ---');

    // Save property information and Firebase Storage URLs
    // to Firestore.
    try {
      await FirebaseFirestore.instance
          .collection('properties')
          .doc(listing.id)
          .set({
        'id': listing.id,
        'ownerId': effectiveOwnerId,
        'ownerType': (isAgent && listingForOwner && resolvedOwnerUid != null)
            ? 'landlord'
            : currentUserRole,
        'managedById': FirebaseAuth.instance.currentUser!.uid,
        'managedByType': currentUserRole,
        'listingForOwner': listingForOwner,
        'representationStatus': listingForOwner
            ? 'owner_contact_pending'
            : 'self_managed',
        'ownerApprovalStatus': listingForOwner
            ? 'pending'
            : 'not_required',
        'ownerName': listingForOwner ? ownerNameController.text.trim() : '',
        'ownerPhone': listingForOwner ? ownerPhoneController.text.trim() : '',
        'ownerEmail': listingForOwner ? ownerEmailController.text.trim() : '',
        'ownerRegistered': resolvedOwnerUid != null,
        'title': listing.title,
        'location': listing.location,
        'propertyType': listing.propertyType,
        'propertySetting': selectedPropertySetting,
        'county': selectedCounty,
        'city': selectedCity,
        'area': selectedArea,
        'rent': listing.rent,
        'bedrooms': listing.bedrooms,
        'bathrooms': listing.bathrooms,
        'size': listing.size,
        'availability': listing.availability,
        'availableFrom': listing.availableFrom != null
            ? Timestamp.fromDate(listing.availableFrom!)
            : null,
        'description': listing.description,
        'amenities': listing.amenities,
        'photoPaths': photoDownloadUrls,
        'submittedAt': Timestamp.fromDate(listing.submittedAt),
        'status': 'pending',
        'verified': false,
      });
      debugPrint('--- PROPERTY DOCUMENT SAVED ---');
    } on FirebaseException catch (e) {
      debugPrint('--- PROPERTY SAVE FAILED: ${e.code} ---');
      debugPrint('MESSAGE: ${e.message}');
      rethrow;
    }

    // ============================================================
    // CREATE OWNER REPRESENTATION REQUEST
    // ============================================================

    if (isAgent && listingForOwner) {
      final requestId =
          FirebaseFirestore.instance
              .collection('ownerRequests')
              .doc()
              .id;

      final ownerEmail =
          ownerEmailController.text.trim().toLowerCase();

      try {
        await FirebaseFirestore.instance
            .collection('ownerRequests')
            .doc(requestId)
            .set({
          'id': requestId,
          'propertyId': listing.id,
          'agentId': FirebaseAuth.instance.currentUser!.uid,
          // Use empty string instead of null so the rule accepts it
          'ownerUid': resolvedOwnerUid ?? '',
          'ownerName': ownerNameController.text.trim(),
          'ownerPhone': ownerPhoneController.text.trim(),
          'ownerEmail': ownerEmail,
          'status': 'pending',
          'adminApprovalStatus': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        });
        debugPrint('--- OWNER REQUEST CREATED ---');
      } on FirebaseException catch (e) {
        debugPrint('--- OWNER REQUEST FAILED: ${e.code} ---');
        debugPrint('MESSAGE: ${e.message}');
        rethrow;
      }
    }

    setState(() {
      isSubmitting = false;
    });

    LandlordListings.add(listing);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Property submitted successfully',
        ),
      ),
    );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PropertySubmittedScreen(
          listing: listing,
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;

    setState(() {
      isSubmitting = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not save property. Please try again.\n$e',
        ),
                duration: const Duration(seconds: 5),
      ),
    );
  }
}

  @override
  Widget build(BuildContext context) {
  return Scaffold(
    backgroundColor: const Color(0xFFFAFAFA),
    appBar: AppBar(
      title: const Text(
        'Add Property',
        style: TextStyle(
          fontWeight: FontWeight.bold,
        ),
      ),
      backgroundColor: Colors.white,
      foregroundColor: textColor,
      elevation: 0,
    ),
    body: Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
          children: [

            // ==================================================
            // 1. PROPERTY DETAILS
            // ==================================================

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.home_work_outlined,
                          color: primaryOrange,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Property Details',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Tell tenants about the home you are listing.',
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),
// ==================================================
// AGENT LISTING TYPE
// ==================================================

if (isAgent) ...[
  const Text(
    'Who are you listing this property for?',
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: secondaryTextColor,
    ),
  ),

  const SizedBox(height: 9),

  Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF8F2),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: primaryOrange.withOpacity(0.10),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                listingForOwner = false;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: 13,
                horizontal: 10,
              ),
              decoration: BoxDecoration(
                color: !listingForOwner
                    ? primaryOrange
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.home_work_outlined,
                    color: !listingForOwner
                        ? Colors.white
                        : secondaryTextColor,
                    size: 22,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'My own property',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: !listingForOwner
                          ? Colors.white
                          : textColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(width: 4),

        Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() {
                listingForOwner = true;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                vertical: 13,
                horizontal: 10,
              ),
              decoration: BoxDecoration(
                color: listingForOwner
                    ? primaryOrange
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.person_outline,
                    color: listingForOwner
                        ? Colors.white
                        : secondaryTextColor,
                    size: 22,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'On behalf of an owner',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: listingForOwner
                          ? Colors.white
                          : textColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  ),

  const SizedBox(height: 20),
],
if (isAgent && listingForOwner) ...[
  const Text(
    'Owner Details',
    style: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: textColor,
    ),
  ),

  const SizedBox(height: 6),

  const Text(
    'Enter the property owner’s contact details.',
    style: TextStyle(
      color: secondaryTextColor,
      fontSize: 13,
    ),
  ),

  const SizedBox(height: 16),

  TextField(
    controller: ownerNameController,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: 'Owner full name',
      hintText: 'e.g. John Kamau',
      prefixIcon: const Icon(Icons.person_outline),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  ),

  const SizedBox(height: 14),

  TextField(
    controller: ownerPhoneController,
    keyboardType: TextInputType.phone,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: 'Owner phone number',
      hintText: 'e.g. 0712345678',
      prefixIcon: const Icon(Icons.phone_outlined),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  ),

  const SizedBox(height: 14),

  TextField(
    controller: ownerEmailController,
    keyboardType: TextInputType.emailAddress,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: 'Owner email',
      hintText: 'e.g. owner@email.com',
      prefixIcon: const Icon(Icons.email_outlined),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
  ),

  const SizedBox(height: 22),
],
// PROPERTY TITLE
const Text(
  'Property title',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 7),

                  TextField(
                    controller: titleController,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      hintText: 'e.g. Modern 2 Bedroom Apartment',
                      prefixIcon: const Icon(
                        Icons.home_outlined,
                        color: primaryOrange,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: primaryOrange,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // PROPERTY TYPE
                  const Text(
                    'Property type',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 7),

                  DropdownButtonFormField<String>(
                    initialValue: selectedPropertyType,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(
                        Icons.apartment_outlined,
                        color: primaryOrange,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                    ),
                    items: propertyTypeOptions
                        .map(
                          (type) => DropdownMenuItem<String>(
                            value: type,
                            child: Text(type),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          selectedPropertyType = value;
                        });
                      }
                    },
                  ),

                  const SizedBox(height: 18),
                  const Text(
                      'Property setting',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    DropdownButtonFormField<String>(
                      initialValue: selectedPropertySetting,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          Icons.location_city_outlined,
                          color: primaryOrange,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFFFF8F2),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: primaryOrange.withOpacity(0.10),
                          ),
                        ),
                      ),
                      items: propertySettingOptions.map(
                        (setting) => DropdownMenuItem<String>(
                          value: setting,
                          child: Text(setting),
                        ),
                      ).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            selectedPropertySetting = value;
                          });
                        }
                      },
                    ),

                    const SizedBox(height: 18),

                  // LOCATION
                  _buildLandlordLocationSelector(),

                  const SizedBox(height: 18),

                  // MONTHLY RENT
                  const Text(
                    'Monthly rent',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 7),

                  TextField(
                    controller: rentController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'e.g. 45000',
                      prefixText: 'KSh ',
                      prefixStyle: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: primaryOrange,
                      ),
                      prefixIcon: const Icon(
                        Icons.payments_outlined,
                        color: primaryOrange,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: primaryOrange,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // BEDROOMS + BATHROOMS
                  Row(
                    children: [

                      Expanded(
                        child: _buildDetailDropdown(
                          label: 'Bedrooms',
                          icon: Icons.bed_outlined,
                          value: selectedBedrooms,
                          items: bedroomOptions,
                          displayValue: (value) {
                            if (value == 'Bedsitter') {
                              return 'Bedsitter';
                            }

                            return '$value Bedroom${value == '1' ? '' : 's'}';
                          },
                          onChanged: (value) {
                            if (value != null) {
                              setState(() {
                                selectedBedrooms = value;
                              });
                            }
                          },
                        ),
                      ),

                      const SizedBox(width: 12),

                      Expanded(
                        child: _buildDetailDropdown(
                          label: 'Bathrooms',
                          icon: Icons.bathtub_outlined,
                          value: selectedBathrooms,
                          items: bathroomOptions,
                          displayValue: (value) {
                            return '$value Bathroom${value == '1' ? '' : 's'}';
                          },
                          onChanged: (value) {
                            if (value != null) {
                              setState(() {
                                selectedBathrooms = value;
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // PROPERTY SIZE
                  const Text(
                    'Property size',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 7),

                  TextField(
                    controller: sizeController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'e.g. 1100',
                      suffixText: 'sq ft',
                      prefixIcon: const Icon(
                        Icons.square_foot_outlined,
                        color: primaryOrange,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: primaryOrange,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            // ==================================================
            // 2. PROPERTY FEATURES
            // ==================================================

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.tune_outlined,
                          color: primaryOrange,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Property Features',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Add availability, amenities and useful information.',
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // AVAILABILITY
                  const Text(
                    'Availability',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),

                  const SizedBox(height: 7),

                    DropdownButtonFormField<String>(
                    initialValue: selectedAvailability,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(
                        Icons.event_available_outlined,
                        color: primaryOrange,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                    ),
                    items: availabilityOptions
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        selectedAvailability = value;

                        // Clear the date when the new value
                        // doesn't need one.
                        if (value != 'Available this month' &&
                            value != 'Available next month') {
                          selectedAvailableFrom = null;
                        }
                      });
                    },
                  ),

                  // NEW — show the date picker only when
                  // availability = "this month" or "next month".
                  if (selectedAvailability ==
                          'Available this month' ||
                      selectedAvailability ==
                          'Available next month') ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final pickedDate = await showDatePicker(
                            context: context,
                            initialDate: selectedAvailableFrom ??
                                DateTime.now()
                                    .add(const Duration(days: 1)),
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 365)),
                          );

                          if (pickedDate != null) {
                            setState(() {
                              selectedAvailableFrom = pickedDate;
                            });
                          }
                        },
                        icon: const Icon(Icons.calendar_month),
                        label: Text(
                          selectedAvailableFrom == null
                              ? 'Choose expected availability date *'
                              : 'Available from: '
                                  '${selectedAvailableFrom!.day}/'
                                  '${selectedAvailableFrom!.month}/'
                                  '${selectedAvailableFrom!.year}',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryOrange,
                          side: const BorderSide(color: primaryOrange),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 22),

                  // AMENITIES
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.star_border_rounded,
                          color: primaryOrange,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Amenities',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Select what is available at the property.',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: amenityOptions.map(
                      (amenity) {
                        final selected =
                            selectedAmenities.contains(amenity);

                        return FilterChip(
                          label: Text(amenity),
                          selected: selected,
                          avatar: Icon(
                            selected ? Icons.check : Icons.add,
                            size: 17,
                            color: selected
                                ? primaryOrange
                                : secondaryTextColor,
                          ),
                          selectedColor:
                              primaryOrange.withOpacity(0.14),
                          backgroundColor:
                              const Color(0xFFF7F7F7),
                          side: BorderSide(
                            color: selected
                                ? primaryOrange.withOpacity(0.35)
                                : Colors.grey.withOpacity(0.15),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          onSelected: (value) {
                            setState(() {
                              if (value) {
                                selectedAmenities.add(amenity);
                              } else {
                                selectedAmenities.remove(amenity);
                              }
                            });
                          },
                        );
                      },
                    ).toList(),
                  ),

                  const SizedBox(height: 22),

                  // DESCRIPTION
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.description_outlined,
                          color: primaryOrange,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Property Description',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Give tenants useful information about the home.',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  TextField(
                    controller: descriptionController,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText:
                          'Describe the property, location, nearby facilities, security, parking and anything tenants should know...',
                      alignLabelWithHint: true,
                      filled: true,
                      fillColor: const Color(0xFFFFF8F2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                          color: primaryOrange.withOpacity(0.10),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: primaryOrange,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 22),

            // ==================================================
            // 3. PROPERTY IMAGES
            // ==================================================

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.photo_library_outlined,
                          color: primaryOrange,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Property Images',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Show tenants what your property looks like.',
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8F2),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: primaryOrange.withOpacity(0.12),
                      ),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lightbulb_outline_rounded,
                          color: primaryOrange,
                          size: 21,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Clear photos of the front, rooms, kitchen, bathroom and parking area can help tenants understand the property before requesting a viewing.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  _buildPhotoSection(),
                ],
              ),
            ),

            const SizedBox(height: 22),

            // ==================================================
            // 4. REVIEW & SUBMIT
            // ==================================================

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: primaryOrange.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.fact_check_outlined,
                          color: primaryOrange,
                          size: 25,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Review & Submit',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Make sure your information is correct before submitting.',
                              style: TextStyle(
                                fontSize: 13,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8F2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: primaryOrange.withOpacity(0.15),
                      ),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: primaryOrange,
                          size: 23,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Your property will be submitted for verification before it becomes visible to tenants.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: isSubmitting
                          ? null
                          : submitProperty,
                      icon: isSubmitting
                          ? const SizedBox(
                              width: 21,
                              height: 21,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.check_circle_outline,
                              size: 23,
                            ),
                      label: Text(
                        isSubmitting
                            ? 'Saving Property...'
                            : 'Submit Property',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryOrange,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  const Center(
                    child: Text(
                      'Your listing will be reviewed before approval.',
                      style: TextStyle(
                        fontSize: 12,
                        color: secondaryTextColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        

              // ==================================================
        // REAL UPLOAD PROGRESS OVERLAY
        // ==================================================

        if (isSubmitting)
          Positioned.fill(
            child: Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_upload_outlined, color: primaryOrange, size: 48),
                      const SizedBox(height: 14),
                      const Text('Uploading property photos', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: textColor)),
                      const SizedBox(height: 22),
                      LinearProgressIndicator(value: uploadProgress, minHeight: 10, borderRadius: BorderRadius.circular(10), color: primaryOrange, backgroundColor: Colors.grey.shade200),
                      const SizedBox(height: 14),
                      Text('${(uploadProgress * 100).toInt()}%', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: primaryOrange)),
                      const SizedBox(height: 6),
                      Text('$uploadedPhotoCount of $totalPhotoCount photos uploaded', textAlign: TextAlign.center, style: const TextStyle(color: secondaryTextColor, fontSize: 15)),
                      if (uploadingCategory.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Uploading: $uploadingCategory', textAlign: TextAlign.center, style: const TextStyle(color: secondaryTextColor, fontSize: 14)),
                      ],
                      const SizedBox(height: 18),
                      const Text('Please keep the app open until the upload is complete.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

Widget _buildDetailDropdown({
  required String label,
  required IconData icon,
  required String value,
  required List<String> items,
  required String Function(String) displayValue,
  required ValueChanged<String?> onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: secondaryTextColor)),
      const SizedBox(height: 7),
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: primaryOrange),
          filled: true,
          fillColor: const Color(0xFFFFF8F2),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: primaryOrange.withOpacity(0.10))),
        ),
        items: items.map((item) => DropdownMenuItem<String>(value: item, child: Text(displayValue(item), overflow: TextOverflow.ellipsis))).toList(),
        onChanged: onChanged,
      ),
    ],
  );
}

Widget _buildPhotoSection() {
  final categories = <String>['Front View', 'Living Room', 'Bedroom', 'Shower Area', 'Kitchen', 'Balcony', 'Parking Area'];
  final categoryIcons = <String, IconData>{
    'Front View': Icons.home_outlined,
    'Living Room': Icons.weekend_outlined,
    'Bedroom': Icons.bed_outlined,
    'Shower Area': Icons.shower_outlined,
    'Kitchen': Icons.kitchen_outlined,
    'Balcony': Icons.balcony_outlined,
    'Parking Area': Icons.local_parking_outlined,
  };

  int activeIndex = categories.indexWhere((category) => categorizedPhotos[category]!.isEmpty);
  if (activeIndex == -1) activeIndex = categories.length - 1;

  int completedCount = 0;
  for (final category in categories) {
    if (categorizedPhotos[category]!.isNotEmpty) completedCount++;
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.orange.shade100)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.photo_library_outlined, color: primaryOrange, size: 25),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Add property photos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Add photos area by area. After completing one area, the next one will open automatically.', style: TextStyle(height: 1.4)),
                  const SizedBox(height: 10),
                  ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: completedCount / categories.length, minHeight: 7, backgroundColor: Colors.orange.shade100, valueColor: const AlwaysStoppedAnimation<Color>(primaryOrange))),
                  const SizedBox(height: 7),
                  Text('$completedCount of ${categories.length} areas completed', style: const TextStyle(color: secondaryTextColor, fontSize: 12, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      ...categories.asMap().entries.map((entry) {
        final index = entry.key;
        final category = entry.value;
        final photos = categorizedPhotos[category]!;
        final isCompleted = photos.isNotEmpty;
        final isActive = index == activeIndex;

        if (isCompleted && !isActive) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.green.shade200)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Container(width: 38, height: 38, decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(10)), child: Icon(categoryIcons[category], color: Colors.green.shade700, size: 21)),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(category, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)), const SizedBox(height: 2), Text('${photos.length} photo${photos.length == 1 ? '' : 's'} added', style: TextStyle(color: Colors.green.shade700, fontSize: 12))])),
                  Icon(Icons.check_circle, color: Colors.green.shade700, size: 21),
                  const SizedBox(width: 4),
                  IconButton(tooltip: 'Add more', onPressed: () => addPhotosToCategory(category), icon: const Icon(Icons.add_photo_alternate_outlined, color: primaryOrange)),
                ],
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 18),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: isActive ? primaryOrange : Colors.grey.shade300, width: isActive ? 2 : 1), boxShadow: isActive ? [BoxShadow(color: primaryOrange.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, 3))] : null),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(padding: const EdgeInsets.all(9), decoration: BoxDecoration(color: primaryOrange.withOpacity(0.10), borderRadius: BorderRadius.circular(10)), child: Icon(categoryIcons[category], color: primaryOrange, size: 23)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(category, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)), const SizedBox(height: 2), Text('Step ${index + 1} of ${categories.length}', style: const TextStyle(color: secondaryTextColor, fontSize: 12))])),
                    if (photos.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: primaryOrange, borderRadius: BorderRadius.circular(10)), child: Text('${photos.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
                  ],
                ),
                const SizedBox(height: 12),
                if (photos.isEmpty)
                  GestureDetector(
                    onTap: () => addPhotosToCategory(category),
                    child: Container(
                      height: 145,
                      width: double.infinity,
                      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: primaryOrange.withOpacity(0.35), width: 1.5)),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: primaryOrange.withOpacity(0.10), shape: BoxShape.circle), child: const Icon(Icons.add_photo_alternate_outlined, size: 35, color: primaryOrange)),
                          const SizedBox(height: 9),
                          Text('Add $category photos', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 4),
                          const Text('Tap to select photos', style: TextStyle(color: secondaryTextColor, fontSize: 12)),
                        ],
                      ),
                    ),
                  )
                else
                  Column(
                    children: [
                      SizedBox(
                        height: 190,
                        child: PageView.builder(
                          itemCount: photos.length,
                          itemBuilder: (context, photoIndex) {
                            return GestureDetector(
                              onTap: () => openFullScreenViewer(category, photoIndex),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(photos[photoIndex].path), fit: BoxFit.cover, errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey.shade200, child: const Icon(Icons.broken_image_outlined, size: 50, color: Colors.grey)))),
                                  Positioned(top: 8, left: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Text('${photoIndex + 1} / ${photos.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)))),
                                  if (category == 'Front View' && photoIndex == 0)
                                    Positioned(left: 8, bottom: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: primaryOrange, borderRadius: BorderRadius.circular(8)), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.star, size: 14, color: Colors.white), SizedBox(width: 4), Text('Main Photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11))]))),
                                  Positioned(right: 8, top: 8, child: GestureDetector(onTap: () => removeCategoryPhoto(category, photoIndex), child: Container(padding: const EdgeInsets.all(6), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.close, color: Colors.white, size: 18)))),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 62,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: photos.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 7),
                          itemBuilder: (context, photoIndex) {
                            return GestureDetector(
                              onTap: () => openFullScreenViewer(category, photoIndex),
                              child: Container(width: 62, decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: photoIndex == 0 ? primaryOrange : Colors.grey.shade300, width: photoIndex == 0 ? 2 : 1)), child: ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.file(File(photos[photoIndex].path), fit: BoxFit.cover))),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => addPhotosToCategory(category), icon: const Icon(Icons.add_photo_alternate_outlined), label: Text('Add More to $category'), style: OutlinedButton.styleFrom(foregroundColor: primaryOrange, side: const BorderSide(color: primaryOrange)))),
                      if (index < categories.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            children: [
                              Icon(Icons.arrow_downward_rounded, size: 18, color: Colors.green.shade700),
                              const SizedBox(width: 6),
                              Expanded(child: Text('Next: ${categories[index + 1]}', style: TextStyle(color: Colors.green.shade700, fontSize: 12, fontWeight: FontWeight.w600))),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      }),
      if (completedCount == categories.length)
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.green.shade200)),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green.shade700, size: 25),
              const SizedBox(width: 10),
              Expanded(child: Text('Great! All property photo areas have been completed.', style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.w600))),
            ],
          ),
        ),
      if (selectedPhotos.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              const Icon(Icons.photo_library, color: primaryOrange),
              const SizedBox(width: 8),
              Expanded(child: Text('${selectedPhotos.length} total photo${selectedPhotos.length == 1 ? '' : 's'} selected', style: const TextStyle(fontWeight: FontWeight.w500))),
            ],
          ),
        ),
    ],
  );
}

  // ============================================================
  // DISPOSE ADD PROPERTY CONTROLLERS
  // ============================================================

  @override
  void dispose() {
    titleController.dispose();
    locationController.dispose();
    rentController.dispose();
    sizeController.dispose();
    descriptionController.dispose();

    ownerNameController.dispose();
    ownerPhoneController.dispose();
    ownerEmailController.dispose();

    super.dispose();
  }
} // <-- THIS is the single closing brace for _AddPropertyScreenState

// ============================================================
// PROPERTY SUBMITTED
// ============================================================

class PropertySubmittedScreen extends StatelessWidget {

  final LandlordListing listing;

  const PropertySubmittedScreen({
    super.key,
    required this.listing,
  });

  Widget _buildPropertyPhoto(String path) {
    Widget placeholder() {
      return Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(
          Icons.broken_image_outlined,
          size: 45,
          color: Colors.grey,
        ),
      );
    }

    if (path.startsWith('http')) {
      return Image.network(
        path,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(
              color: primaryOrange,
            ),
          );
        },
        errorBuilder: (_, __, ___) => placeholder(),
      );
    }

    return Image.file(
      File(path),
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Property Submitted'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 10),

            const CircleAvatar(
              radius: 45,
              backgroundColor: availableGreen,
              child: Icon(
                Icons.check,
                size: 50,
                color: Colors.white,
              ),
            ),

            const SizedBox(height: 20),

            const Text(
              'Property Submitted!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 10),

            const Text(
              'Your property has been successfully saved and submitted for verification.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryTextColor,
                height: 1.5,
                fontSize: 15,
              ),
            ),

            const SizedBox(height: 22),

            // PROPERTY CARD
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // MAIN PHOTO
                  if (listing.photoPaths.isNotEmpty)
                    SizedBox(
                      height: 220,
                      width: double.infinity,
                      child: _buildPropertyPhoto(
                        listing.photoPaths.first,
                      ),
                    )
                  else
                    Container(
                      height: 220,
                      width: double.infinity,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.apartment,
                        size: 65,
                        color: Colors.grey,
                      ),
                    ),

                  // HORIZONTAL PHOTO THUMBNAILS
                  if (listing.photoPaths.length > 1)
                    SizedBox(
                      height: 86,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        scrollDirection: Axis.horizontal,
                        itemCount:
                            listing.photoPaths.length - 1,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          return ClipRRect(
                            borderRadius:
                                BorderRadius.circular(8),
                            child: SizedBox(
                              width: 100,
                              child: _buildPropertyPhoto(
                                listing.photoPaths[index + 1],
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                  // PROPERTY DETAILS
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          listing.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 7),

                        Row(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.location_on_outlined,
                              size: 18,
                              color: secondaryTextColor,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                listing.location,
                                style: const TextStyle(
                                  color: secondaryTextColor,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        Text(
                          'KSh ${listing.rent} / month',
                          style: const TextStyle(
                            color: primaryOrange,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            const Icon(
                              Icons.bed_outlined,
                              size: 18,
                              color: secondaryTextColor,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              listing.bedrooms == 0
                                  ? 'Bedsitter'
                                  : '${listing.bedrooms} bedroom'
                                      '${listing.bedrooms == 1 ? '' : 's'}',
                            ),
                            const SizedBox(width: 16),
                            const Icon(
                              Icons.bathtub_outlined,
                              size: 18,
                              color: secondaryTextColor,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${listing.bathrooms} bath',
                            ),
                          ],
                        ),

                        if (listing.photoPaths.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            '${listing.photoPaths.length} photos attached',
                            style: const TextStyle(
                              color: secondaryTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ],

                        const SizedBox(height: 14),

                        // VERIFICATION STATUS
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius:
                                BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.orange.shade100,
                            ),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.hourglass_empty,
                                color: primaryOrange,
                              ),
                              SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Pending verification',
                                      style: TextStyle(
                                        color: primaryOrange,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      'Your property is waiting for review.',
                                      style: TextStyle(
                                        color: secondaryTextColor,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // WHAT HAPPENS NEXT
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: primaryOrange,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'What happens next?',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    _nextStep(
                      icon: Icons.fact_check_outlined,
                      title: 'Property review',
                      text:
                          'Your property details and photos will be reviewed.',
                    ),

                    const SizedBox(height: 10),

                    _nextStep(
                      icon: Icons.verified_outlined,
                      title: 'Verification',
                      text:
                          'Once approved, your property can become visible to tenants.',
                    ),

                    const SizedBox(height: 10),

                    _nextStep(
                      icon: Icons.people_outline,
                      title: 'Reach tenants',
                      text:
                          'Tenants will be able to discover your property and request a viewing.',
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 25),

            // VIEW LISTINGS
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const MyListingsScreen(),
                    ),
                  );
                },
                icon: const Icon(
                  Icons.home_work_outlined,
                ),
                label: const Text('View My Listings'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            // BACK HOME
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const MainNavigationScreen(),
                    ),
                    (route) => false,
                  );
                },
                icon: const Icon(Icons.home_outlined),
                label: const Text('Back to Home'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 15,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 15),
          ],
        ),
      ),
    );
  }

  Widget _nextStep({
    required IconData icon,
    required String title,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 21,
          color: primaryOrange,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: const TextStyle(
                  color: secondaryTextColor,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
// ============================================================
// MAIN NAVIGATION
// ============================================================

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState
    extends State<MainNavigationScreen> {
  int selectedIndex = 0;

  String? currentUserId;

  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();

    currentUserId =
        FirebaseAuth.instance.currentUser?.uid;

    _authSubscription =
        FirebaseAuth.instance.authStateChanges().listen(
      (user) {
        final newUserId = user?.uid;

        if (newUserId == currentUserId) {
          return;
        }

        currentUserId = newUserId;

        if (!mounted) return;

        // Every new account starts from Home.
        setState(() {
          selectedIndex = 0;
        });
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Widget _buildCurrentScreen() {
    final userId =
        FirebaseAuth.instance.currentUser?.uid ??
            'logged_out';

      switch (selectedIndex) {
      case 0:
        return HomeScreen(
          onProfileTap: () {
            setState(() {
              selectedIndex = 3; // Index 3 is the Profile tab
            });
          },
        );

      case 1:
  return SavedScreen(
    key: ValueKey(
      'saved_$userId',
    ),
    onAccessDenied: () {
      if (!mounted) return;

      setState(() {
        selectedIndex = 0;
      });
    },
  );

      case 2:
  return ViewingsScreen(
    key: ValueKey(
      'viewings_$userId',
    ),
    onAccessDenied: () {
      if (!mounted) return;

      setState(() {
        selectedIndex = 0;
      });
    },
  );

      case 3:
        return const ProfileScreen();

      default:
        return const HomeScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildCurrentScreen(),

      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,

        onDestinationSelected: (index) {
          setState(() {
            selectedIndex = index;
          });
        },

        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),

          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: 'Saved',
          ),

          NavigationDestination(
            icon: Icon(
              Icons.calendar_month_outlined,
            ),
            selectedIcon: Icon(
              Icons.calendar_month,
            ),
            label: 'Viewings',
          ),

          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
// ============================================================
// AGENT OWNER REQUESTS SCREEN
// ============================================================

class AgentOwnerRequestsScreen extends StatelessWidget {
  const AgentOwnerRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Please login to view owner requests.',
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Owner Requests'),
      ),
      backgroundColor: const Color(0xFFFAFAFA),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('ownerRequests')
            .where(
              'agentId',
              isEqualTo: user.uid,
            )
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Could not load owner requests.\n\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          if (documents.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                  'You do not have any owner requests yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 16,
                  ),
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: documents.length,
            itemBuilder: (context, index) {
              final data =
                  documents[index].data()
                      as Map<String, dynamic>;

              final ownerName =
                  data['ownerName']?.toString() ??
                      'Unknown owner';

              final ownerPhone =
                  data['ownerPhone']?.toString() ?? '';

              final ownerEmail =
                  data['ownerEmail']?.toString() ?? '';

              final status =
                  data['status']?.toString() ??
                      'pending';

              final propertyId =
                  data['propertyId']?.toString() ?? '';
                // ============================================================
                // REQUEST STATUS DISPLAY
                // ============================================================

                String statusText;
                Color statusColor;
                IconData statusIcon;

                if (status == 'pending') {
                  statusText = 'WAITING FOR OWNER';
                  statusColor = Colors.orange;
                  statusIcon = Icons.pending_outlined;
                } else if (status == 'owner_approved') {
                  statusText = 'PENDING RENTALAPP VERIFICATION';
                  statusColor = Colors.blue;
                  statusIcon =
                      Icons.admin_panel_settings_outlined;
                } else if (status == 'approved') {
                  statusText = 'VERIFIED';
                  statusColor = Colors.green;
                  statusIcon = Icons.verified_outlined;
                } else if (status == 'admin_rejected') {
                  statusText = 'REJECTED BY RENTALAPP';
                  statusColor = Colors.red;
                  statusIcon = Icons.cancel_outlined;
                } else if (status == 'rejected') {
                  statusText = 'REJECTED BY OWNER';
                  statusColor = Colors.red;
                  statusIcon = Icons.cancel_outlined;
                } else {
                  statusText = status.toUpperCase();
                  statusColor = secondaryTextColor;
                  statusIcon = Icons.info_outline;
                }


              return Card(
                margin:
                    const EdgeInsets.only(bottom: 14),
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(16),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.person_outline,
                            color: primaryOrange,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              ownerName,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      Text(
                        'Phone: $ownerPhone',
                        style: const TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),

                      const SizedBox(height: 6),

                      Text(
                        'Email: $ownerEmail',
                        style: const TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),

                      const SizedBox(height: 6),

  // ============================================================
// PROPERTY TITLE
// ============================================================

FutureBuilder<DocumentSnapshot>(
  future: FirebaseFirestore.instance
      .collection('properties')
      .doc(propertyId)
      .get(),
  builder: (context, propertySnapshot) {
    String propertyTitle = 'Property';

    if (propertySnapshot.hasData &&
        propertySnapshot.data!.exists) {
      final propertyData =
          propertySnapshot.data!.data()
              as Map<String, dynamic>?;

      propertyTitle =
          propertyData?['title']?.toString().trim() ??
              'Property';

      if (propertyTitle.isEmpty) {
        propertyTitle = 'Property';
      }
    }

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          propertyTitle,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 5),

        Text(
          'Property ID: $propertyId',
          style: const TextStyle(
            color: secondaryTextColor,
            fontSize: 12,
          ),
        ),
      ],
    );
  },
),
// ============================================================
// STATUS
// ============================================================

Container(
  width: double.infinity,
  padding: const EdgeInsets.symmetric(
    vertical: 13,
    horizontal: 14,
  ),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: status == 'approved'
          ? Colors.green.withValues(alpha: 0.30)
          : status == 'rejected' ||
                  status == 'admin_rejected'
              ? Colors.red.withValues(alpha: 0.30)
              : status == 'owner_approved'
                  ? Colors.blue.withValues(alpha: 0.30)
                  : Colors.orange.withValues(alpha: 0.30),
    ),
  ),
  child: Row(
    children: [
      Icon(
        status == 'approved'
            ? Icons.check_circle_outline
            : status == 'rejected' ||
                    status == 'admin_rejected'
                ? Icons.cancel_outlined
                : status == 'owner_approved'
                    ? Icons.admin_panel_settings_outlined
                    : Icons.pending_outlined,
        size: 21,
        color: status == 'approved'
            ? Colors.green
            : status == 'rejected' ||
                    status == 'admin_rejected'
                ? Colors.red
                : status == 'owner_approved'
                    ? Colors.blue
                    : Colors.orange,
      ),

      const SizedBox(width: 10),

      Expanded(
        child: Text(
          status == 'approved'
              ? 'VERIFIED'
              : status == 'rejected'
                  ? 'REJECTED BY OWNER'
                  : status == 'admin_rejected'
                      ? 'REJECTED BY RENTALAPP'
                      : status == 'owner_approved'
                          ? 'PENDING RENTALAPP VERIFICATION'
                          : 'WAITING FOR OWNER',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: status == 'approved'
                ? Colors.green
                : status == 'rejected' ||
                        status == 'admin_rejected'
                    ? Colors.red
                    : status == 'owner_approved'
                        ? Colors.blue
                        : Colors.orange,
          ),
        ),
      ),
    ],
  ),
),
                      // ============================================================
// REJECTION REASON
// ============================================================

if (status == 'rejected' ||
    status == 'admin_rejected') ...[
  const SizedBox(height: 12),

  Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.red.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: Colors.red.withValues(alpha: 0.20),
      ),
    ),
    child: Text(
      status == 'admin_rejected'
          ? 'RentalApp rejection reason: '
              '${data['adminRejectionReason']?.toString() ?? 'No reason provided.'}'
          : 'Owner rejection reason: '
              '${data['rejectionReason']?.toString() ?? 'No reason provided.'}',
      style: const TextStyle(
        color: Colors.red,
        fontSize: 13,
      ),
    ),
  ),
],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
// ============================================================
// OWNER AGENT REQUESTS SCREEN
// ============================================================

class OwnerAgentRequestsScreen extends StatelessWidget {
  const OwnerAgentRequestsScreen({super.key});

  // ============================================================
  // APPROVE REQUEST — OWNER APPROVAL ONLY
  // ============================================================

  Future<void> _approveRequest(
    BuildContext context,
    String requestId,
    Map<String, dynamic> data,
  ) async {
    final propertyId =
        data['propertyId']?.toString() ?? '';

    final agentId =
        data['agentId']?.toString() ?? '';

    final ownerUid =
        data['ownerUid']?.toString() ?? '';

    if (propertyId.isEmpty ||
        agentId.isEmpty ||
        ownerUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This request is missing required information and cannot be approved.',
          ),
        ),
      );

      return;
    }

    // ============================================================
    // CONFIRM OWNER APPROVAL
    // ============================================================

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Text(
            'Approve Agent Request?',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'Your approval will be recorded and the request '
            'will then be sent to KejaFind for verification. '
            'The agent will not be fully authorized until '
            'KejaFind completes the verification.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  false,
                );
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  true,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryOrange,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'Approve & Send for Review',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    // ============================================================
    // UPDATE FIRESTORE
    // ============================================================

    try {
      final firestore =
          FirebaseFirestore.instance;

      final batch =
          firestore.batch();

      final requestRef = firestore
          .collection('ownerRequests')
          .doc(requestId);

      final propertyRef = firestore
          .collection('properties')
          .doc(propertyId);

      // ============================================================
      // OWNER REQUEST
      // ============================================================

      batch.update(
        requestRef,
        {
          // Owner has approved.
          'status': 'owner_approved',

          'ownerApprovalStatus': 'approved',

          'ownerApprovedAt':
              FieldValue.serverTimestamp(),

          // Admin still needs to review.
          'adminApprovalStatus': 'pending',

          'adminReviewedAt':
              FieldValue.delete(),

          'adminRejectionReason':
              FieldValue.delete(),

          'rejectionReason':
              FieldValue.delete(),

          'rejectedAt':
              FieldValue.delete(),
        },
      );

      // ============================================================
      // PROPERTY
      // ============================================================
      //
      // IMPORTANT — DO NOT CHANGE:
      //   - 'ownerId'      (set correctly at creation time; the
      //                     security rules forbid changing it)
      //   - 'managedById'  (already the agent's uid from creation)
      //   - 'ownerType'    (set correctly at creation time)
      //
      // Only the representation-related status fields are updated
      // here. The rules whitelist permits exactly these keys for
      // the owner's approval step.

      batch.update(
        propertyRef,
        {
          // Owner approved, but admin has not approved yet.
          'ownerApprovalStatus': 'approved',
          'adminApprovalStatus': 'pending',

          'representationStatus': 'pending_admin',

          'ownerApprovedAt':
              FieldValue.serverTimestamp(),

          'adminApprovedAt':
              FieldValue.delete(),

          'adminRejectionReason':
              FieldValue.delete(),
        },
      );

      await batch.commit();

      if (!context.mounted) return;

      // ============================================================
      // OWNER MESSAGE
      // ============================================================

      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(18),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.check_circle_outline,
                  color: Colors.green,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Approval Received',
                  ),
                ),
              ],
            ),
            content: const Text(
              'Your approval has been recorded successfully.\n\n'
              'The request is now awaiting KejaFind verification. '
              'The agent will only become fully authorized after '
              'the admin verification process is completed.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(
                    dialogContext,
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      primaryOrange,
                  foregroundColor:
                      Colors.white,
                ),
                child: const Text(
                  'Done',
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not submit the approval.\n$e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // REJECT REQUEST
  // ============================================================

  Future<void> _rejectRequest(
    BuildContext context,
    String requestId,
    Map<String, dynamic> data,
  ) async {
    final propertyId =
        data['propertyId']?.toString() ?? '';

    final reasons = <String>[
      'I do not know this agent',
      'Property information is incorrect',
      'I no longer want the property listed',
      'I already have another agent',
      'I am not the property owner',
      'Other',
    ];

    String? selectedReason;

    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              title: const Text(
                'Reject Agent Request',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    const Align(
                      alignment:
                          Alignment.centerLeft,
                      child: Text(
                        'Why are you rejecting this request?',
                        style: TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    ...reasons.map(
                      (item) {
                        return RadioListTile<String>(
                          value: item,
                          groupValue:
                              selectedReason,
                          contentPadding:
                              EdgeInsets.zero,
                          title: Text(
                            item,
                            style:
                                const TextStyle(
                              fontSize: 14,
                            ),
                          ),
                          onChanged: (value) {
                            setDialogState(() {
                              selectedReason =
                                  value;
                            });
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                    );
                  },
                  child:
                      const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed:
                      selectedReason == null
                          ? null
                          : () {
                              Navigator.pop(
                                dialogContext,
                                selectedReason,
                              );
                            },
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        Colors.red,
                    foregroundColor:
                        Colors.white,
                  ),
                  child:
                      const Text('Reject'),
                ),
              ],
            );
          },
        );
      },
    );

    if (reason == null) {
      return;
    }

    try {
      final firestore =
          FirebaseFirestore.instance;

      final batch =
          firestore.batch();

      final requestRef = firestore
          .collection('ownerRequests')
          .doc(requestId);

      // ==========================================================
      // UPDATE REQUEST
      // ==========================================================

      batch.update(
        requestRef,
        {
          'status': 'rejected',
          'rejectedAt':
              FieldValue.serverTimestamp(),
          'rejectionReason': reason,
          'approvedAt':
              FieldValue.delete(),
        },
      );

      // ==========================================================
      // UPDATE PROPERTY
      // ==========================================================

      if (propertyId.isNotEmpty) {
        final propertyRef = firestore
            .collection('properties')
            .doc(propertyId);

        batch.update(
          propertyRef,
          {
            'ownerApprovalStatus':
                'rejected',
            'representationStatus':
                'rejected',
            'rejectionReason':
                reason,
          },
        );
      }

      await batch.commit();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Agent request rejected.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not reject the request.\n$e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Please login to view agent requests.',
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Agent Requests',
        ),
      ),
      backgroundColor:
          const Color(0xFFFAFAFA),

      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('ownerRequests')
            .where(
              'ownerUid',
              isEqualTo: user.uid,
            )
            .snapshots(),

        builder: (
          context,
          snapshot,
        ) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child:
                  CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding:
                    const EdgeInsets.all(20),
                child: Text(
                  'Could not load agent requests.\n\n'
                  '${snapshot.error}',
                  textAlign:
                      TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          if (documents.isEmpty) {
            return const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(30),
                child: Text(
                  'You do not have any agent requests yet.',
                  textAlign:
                      TextAlign.center,
                  style: TextStyle(
                    color:
                        secondaryTextColor,
                    fontSize: 16,
                  ),
                ),
              ),
            );
          }

          return ListView.builder(
            padding:
                const EdgeInsets.all(16),
            itemCount:
                documents.length,

            itemBuilder: (
              context,
              index,
            ) {
              final document =
                  documents[index];

              final data =
                  document.data()
                      as Map<String, dynamic>;

              final ownerName =
                  data['ownerName']
                          ?.toString() ??
                      'Property owner';

              final ownerPhone =
                  data['ownerPhone']
                          ?.toString() ??
                      '';

              final ownerEmail =
                  data['ownerEmail']
                          ?.toString() ??
                      '';

              final agentId =
                  data['agentId']
                          ?.toString() ??
                      '';

              final propertyId =
                  data['propertyId']
                          ?.toString() ??
                      '';

              // Normalize the status.
              final status =
                  (data['status']
                              ?.toString() ??
                          'pending')
                      .trim()
                      .toLowerCase();

              final rejectionReason =
                  data['rejectionReason']
                          ?.toString() ??
                      '';

              // ==========================================================
              // REQUEST CARD
              // ==========================================================

              return Card(
                margin:
                    const EdgeInsets.only(
                  bottom: 18,
                ),
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                    18,
                  ),
                ),

                child: Padding(
                  padding:
                      const EdgeInsets.all(
                    18,
                  ),

                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,

                    children: [
                      // ==================================================
                      // HEADER
                      // ==================================================

                      Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration:
                                BoxDecoration(
                              color:
                                  primaryOrange
                                      .withValues(
                                alpha: 0.10,
                              ),
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                14,
                              ),
                            ),
                            child:
                                const Icon(
                              Icons
                                  .handshake_outlined,
                              color:
                                  primaryOrange,
                            ),
                          ),

                          const SizedBox(
                            width: 12,
                          ),

                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                const Text(
                                  'Agent Request',
                                  style:
                                      TextStyle(
                                    fontSize: 18,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),

                                const SizedBox(
                                  height: 5,
                                ),

                                Text(
                                  status
                                      .toUpperCase(),
                                  style:
                                      TextStyle(
                                    fontSize: 12,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                    color:
                                        status ==
                                                'approved'
                                            ? Colors
                                                .green
                                            : status ==
                                                    'rejected'
                                                ? Colors
                                                    .red
                                                : Colors
                                                    .orange,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(
                        height: 20,
                      ),

                      // ==================================================
                      // MESSAGE
                      // ==================================================

                      const Text(
                        'An agent is requesting permission '
                        'to manage this property on your behalf.',
                        style: TextStyle(
                          fontSize: 15,
                        ),
                      ),

                      const SizedBox(
                        height: 18,
                      ),

                      // ==================================================
                      // PROPERTY
                      // ==================================================

                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets
                                .all(14),
                        decoration:
                            BoxDecoration(
                          color:
                              const Color(
                            0xFFF5F5F5,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Property',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),

                            const SizedBox(
                              height: 8,
                            ),

// ============================================================
// PROPERTY TITLE
// ============================================================

FutureBuilder<DocumentSnapshot>(
  future: FirebaseFirestore.instance
      .collection('properties')
      .doc(propertyId)
      .get(),
  builder: (context, propertySnapshot) {
    String propertyTitle = 'Property';

    if (propertySnapshot.hasData &&
        propertySnapshot.data!.exists) {
      final propertyData =
          propertySnapshot.data!.data()
              as Map<String, dynamic>?;

      propertyTitle =
          propertyData?['title']?.toString().trim() ??
              'Property';

      if (propertyTitle.isEmpty) {
        propertyTitle = 'Property';
      }
    }

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          propertyTitle,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 5),

        Text(
          'Property ID: $propertyId',
          style: const TextStyle(
            color: secondaryTextColor,
            fontSize: 12,
          ),
        ),
      ],
    );
  },
),
                          ],
                        ),
                      ),

                      const SizedBox(
                        height: 16,
                      ),

                      // ==================================================
                      // OWNER INFORMATION
                      // ==================================================

                      Text(
                        'Owner: $ownerName',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 6,
                      ),

                      Text(
                        'Phone: $ownerPhone',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 6,
                      ),

                      Text(
                        'Email: $ownerEmail',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 6,
                      ),

                      Text(
                        'Agent ID: $agentId',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),

                      const SizedBox(
                        height: 20,
                      ),

                          // ============================================================
// STATUS
// ============================================================

Container(
  width: double.infinity,
  padding: const EdgeInsets.symmetric(
    vertical: 13,
    horizontal: 14,
  ),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: status == 'approved'
          ? Colors.green.withValues(alpha: 0.30)
          : status == 'rejected' ||
                  status == 'admin_rejected'
              ? Colors.red.withValues(alpha: 0.30)
              : status == 'owner_approved'
                  ? Colors.blue.withValues(alpha: 0.30)
                  : Colors.orange.withValues(alpha: 0.30),
    ),
  ),
  child: Row(
    children: [
      Icon(
        status == 'approved'
            ? Icons.check_circle_outline
            : status == 'rejected' ||
                    status == 'admin_rejected'
                ? Icons.cancel_outlined
                : status == 'owner_approved'
                    ? Icons.admin_panel_settings_outlined
                    : Icons.pending_outlined,
        size: 21,
        color: status == 'approved'
            ? Colors.green
            : status == 'rejected' ||
                    status == 'admin_rejected'
                ? Colors.red
                : status == 'owner_approved'
                    ? Colors.blue
                    : Colors.orange,
      ),

      const SizedBox(width: 10),

      Expanded(
        child: Text(
          status == 'approved'
              ? 'VERIFIED'
              : status == 'rejected'
                  ? 'REJECTED BY OWNER'
                  : status == 'admin_rejected'
                      ? 'REJECTED BY RENTALAPP'
                      : status == 'owner_approved'
                          ? 'PENDING RENTALAPP VERIFICATION'
                          : 'WAITING FOR OWNER',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: status == 'approved'
                ? Colors.green
                : status == 'rejected' ||
                        status == 'admin_rejected'
                    ? Colors.red
                    : status == 'owner_approved'
                        ? Colors.blue
                        : Colors.orange,
          ),
        ),
      ),
    ],
  ),
),
                      // ==================================================
                      // REJECTION REASON
                      // ==================================================

                      if (status ==
                              'rejected' &&
                          rejectionReason
                              .isNotEmpty) ...[
                        const SizedBox(
                          height: 12,
                        ),

                        Container(
                          width:
                              double.infinity,
                          padding:
                              const EdgeInsets
                                  .all(14),
                          decoration:
                              BoxDecoration(
                            color: Colors.red
                                .withValues(
                              alpha: 0.06,
                            ),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              12,
                            ),
                          ),
                          child: Text(
                            'Rejection reason:\n'
                            '$rejectionReason',
                            style:
                                const TextStyle(
                              color:
                                  Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],

                      // ==================================================
                      // ACTIONS
                      // ==================================================

                      if (status ==
                          'pending') ...[
                        const SizedBox(
                          height: 22,
                        ),

                        const Divider(),

                        const SizedBox(
                          height: 14,
                        ),

                        const Text(
                          'What would you like to do?',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                FontWeight.w600,
                          ),
                        ),

                        const SizedBox(
                          height: 12,
                        ),

                        Row(
                          children: [
                            // ==========================================
                            // REJECT
                            // ==========================================

                            Expanded(
                              child:
                                  OutlinedButton(
                                onPressed: () {
                                  _rejectRequest(
                                    context,
                                    document.id,
                                    data,
                                  );
                                },
                                style:
                                    OutlinedButton
                                        .styleFrom(
                                  foregroundColor:
                                      Colors.red,
                                  side:
                                      const BorderSide(
                                    color:
                                        Colors.red,
                                    width: 1.2,
                                  ),
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    vertical:
                                        14,
                                  ),
                                ),
                                child:
                                    const Text(
                                  'Reject',
                                  style:
                                      TextStyle(
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(
                              width: 12,
                            ),

                            // ==========================================
                            // APPROVE
                            // ==========================================

                            Expanded(
                              child:
                                  ElevatedButton(
                                onPressed: () {
                                  _approveRequest(
                                    context,
                                    document.id,
                                    data,
                                  );
                                },
                                style:
                                    ElevatedButton
                                        .styleFrom(
                                  backgroundColor:
                                      primaryOrange,
                                  foregroundColor:
                                      Colors.white,
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    vertical:
                                        14,
                                  ),
                                ),
                                child:
                                    const Text(
                                  'Approve',
                                  style:
                                      TextStyle(
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
// ============================================================
// ADMIN AGENT VERIFICATION SCREEN
// ============================================================

class AdminAgentVerificationScreen
    extends StatelessWidget {
  const AdminAgentVerificationScreen({
    super.key,
  });

  // ============================================================
  // APPROVE REPRESENTATION
  // ============================================================

  Future<void> _approveRepresentation(
    BuildContext context,
    String requestId,
    Map<String, dynamic> data,
  ) async {
    final propertyId =
        data['propertyId']?.toString() ?? '';

    final ownerUid =
        data['ownerUid']?.toString() ?? '';

    final agentId =
        data['agentId']?.toString() ?? '';

    if (propertyId.isEmpty ||
        ownerUid.isEmpty ||
        agentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This request is missing required information and cannot be approved.',
          ),
        ),
      );

      return;
    }

    // ============================================================
    // CONFIRM ADMIN APPROVAL
    // ============================================================

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(18),
          ),
          title: const Text(
            'Approve Representation?',
            style: TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'This will complete the verification process '
            'and authorize the agent to manage this property.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  false,
                );
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  true,
                );
              },
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    primaryOrange,
                foregroundColor:
                    Colors.white,
              ),
              child: const Text(
                'Approve',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    // ============================================================
    // UPDATE FIRESTORE
    // ============================================================

    try {
      final firestore =
          FirebaseFirestore.instance;

      final batch =
          firestore.batch();

      final requestRef = firestore
          .collection('ownerRequests')
          .doc(requestId);

      final propertyRef = firestore
          .collection('properties')
          .doc(propertyId);

      // ============================================================
      // UPDATE OWNER REQUEST
      // ============================================================

      batch.update(
        requestRef,
        {
          'status': 'approved',

          'ownerApprovalStatus':
              'approved',

          'adminApprovalStatus':
              'approved',

          'adminApprovedAt':
              FieldValue.serverTimestamp(),

          'adminRejectionReason':
              FieldValue.delete(),

          'rejectionReason':
              FieldValue.delete(),

          'adminRejectedAt':
              FieldValue.delete(),

          'rejectedAt':
              FieldValue.delete(),
        },
      );

      // ============================================================
      // UPDATE PROPERTY
      // ============================================================

      batch.update(
        propertyRef,
        {
          // Confirmed property owner.
          'ownerId': ownerUid,
          'ownerType': 'landlord',

          // Confirmed managing agent.
          'managedById': agentId,
          'managedByType': 'agent',

          // Owner approval.
          'ownerApprovalStatus':
              'approved',

          // Admin approval.
          'adminApprovalStatus':
              'approved',

          // Final representation status.
          'representationStatus':
              'approved',

          // FINAL PROPERTY STATUS.
          'status': 'approved',
          'verified': true,

          'adminApprovedAt':
              FieldValue.serverTimestamp(),

          // Remove old rejection information.
          'adminRejectionReason':
              FieldValue.delete(),

          'rejectionReason':
              FieldValue.delete(),

          'adminRejectedAt':
              FieldValue.delete(),

          'rejectedAt':
              FieldValue.delete(),
        },
      );

      await batch.commit();

      if (!context.mounted) return;

      // ============================================================
      // SUCCESS MESSAGE
      // ============================================================

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(
                18,
              ),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  color: Colors.green,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Verification Complete',
                  ),
                ),
              ],
            ),
            content: const Text(
              'The agent representation has been verified successfully.\n\n'
              'The property is now approved and the agent is authorized '
              'to manage this property.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(
                    dialogContext,
                  );
                },
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      primaryOrange,
                  foregroundColor:
                      Colors.white,
                ),
                child:
                    const Text('Done'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not approve the representation.\n$e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // REJECT REPRESENTATION
  // ============================================================

  Future<void> _rejectRepresentation(
    BuildContext context,
    String requestId,
    Map<String, dynamic> data,
  ) async {
    final propertyId =
        data['propertyId']?.toString() ?? '';

    final reasons = <String>[
      'Owner approval could not be verified',
      'Agent information requires verification',
      'Property information requires verification',
      'Representation agreement required',
      'Information provided is inconsistent',
      'Other',
    ];

    String? selectedReason;

    // ============================================================
    // SELECT REJECTION REASON
    // ============================================================

    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return AlertDialog(
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  18,
                ),
              ),
              title: const Text(
                'Reject Verification',
                style: TextStyle(
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
              content:
                  SingleChildScrollView(
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    const Align(
                      alignment:
                          Alignment.centerLeft,
                      child: Text(
                        'Please select a reason.',
                        style: TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    ...reasons.map(
                      (item) {
                        return RadioListTile<
                            String>(
                          value: item,
                          groupValue:
                              selectedReason,
                          contentPadding:
                              EdgeInsets.zero,
                          title: Text(
                            item,
                            style:
                                const TextStyle(
                              fontSize: 14,
                            ),
                          ),
                          onChanged:
                              (value) {
                            setDialogState(
                              () {
                                selectedReason =
                                    value;
                              },
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                    );
                  },
                  child:
                      const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed:
                      selectedReason == null
                          ? null
                          : () {
                              Navigator.pop(
                                dialogContext,
                                selectedReason,
                              );
                            },
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        Colors.red,
                    foregroundColor:
                        Colors.white,
                  ),
                  child:
                      const Text('Reject'),
                ),
              ],
            );
          },
        );
      },
    );

    if (reason == null) {
      return;
    }

    // ============================================================
    // UPDATE FIRESTORE
    // ============================================================

    try {
      final firestore =
          FirebaseFirestore.instance;

      final batch =
          firestore.batch();

      final requestRef = firestore
          .collection('ownerRequests')
          .doc(requestId);

      // ============================================================
      // UPDATE OWNER REQUEST
      // ============================================================

      batch.update(
        requestRef,
        {
          'status': 'admin_rejected',

          'adminApprovalStatus':
              'rejected',

          'adminRejectedAt':
              FieldValue.serverTimestamp(),

          'adminRejectionReason':
              reason,

          'adminApprovedAt':
              FieldValue.delete(),
        },
      );

      // ============================================================
      // UPDATE PROPERTY
      // ============================================================

      if (propertyId.isNotEmpty) {
        final propertyRef = firestore
            .collection('properties')
            .doc(propertyId);

        batch.update(
          propertyRef,
          {
            // Admin rejected the representation.
            'adminApprovalStatus':
                'rejected',

            'representationStatus':
                'rejected',

            // FINAL PROPERTY STATUS.
            'status':
                'admin_rejected',

            'verified':
                false,

            'adminRejectionReason':
                reason,

            'adminRejectedAt':
                FieldValue.serverTimestamp(),

            'adminApprovedAt':
                FieldValue.delete(),
          },
        );
      }

      await batch.commit();

      if (!context.mounted) return;

      // ============================================================
      // REJECTION MESSAGE
      // ============================================================

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(
                18,
              ),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.cancel_outlined,
                  color: Colors.red,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Verification Rejected',
                  ),
                ),
              ],
            ),
            content: Text(
              'The agent representation has been rejected.\n\n'
              'Reason:\n$reason',
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(
                    dialogContext,
                  );
                },
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      primaryOrange,
                  foregroundColor:
                      Colors.white,
                ),
                child:
                    const Text('Done'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not reject the representation.\n$e',
          ),
        ),
      );
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Admin Verification',
        ),
      ),
      backgroundColor:
          const Color(0xFFFAFAFA),

      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('ownerRequests')
            .where(
              'adminApprovalStatus',
              isEqualTo: 'pending',
            )
            .snapshots(),

        builder: (
          context,
          snapshot,
        ) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child:
                  CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding:
                    const EdgeInsets.all(20),
                child: Text(
                  'Could not load verification requests.\n\n'
                  '${snapshot.error}',
                  textAlign:
                      TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          if (documents.isEmpty) {
            return const Center(
              child: Padding(
                padding:
                    EdgeInsets.all(30),
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_outlined,
                      size: 55,
                      color:
                          secondaryTextColor,
                    ),
                    SizedBox(
                      height: 15,
                    ),
                    Text(
                      'No verification requests',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    SizedBox(
                      height: 8,
                    ),
                    Text(
                      'There are currently no agent representations awaiting admin verification.',
                      textAlign:
                          TextAlign.center,
                      style: TextStyle(
                        color:
                            secondaryTextColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding:
                const EdgeInsets.all(16),
            itemCount:
                documents.length,

            itemBuilder: (
              context,
              index,
            ) {
              final document =
                  documents[index];

              final data =
                  document.data()
                      as Map<String, dynamic>;

              final ownerName =
                  data['ownerName']
                          ?.toString() ??
                      'Unknown owner';

              final ownerPhone =
                  data['ownerPhone']
                          ?.toString() ??
                      '';

              final ownerEmail =
                  data['ownerEmail']
                          ?.toString() ??
                      '';

              final ownerUid =
                  data['ownerUid']
                          ?.toString() ??
                      '';

              final agentId =
                  data['agentId']
                          ?.toString() ??
                      '';

              final propertyId =
                  data['propertyId']
                          ?.toString() ??
                      '';

              final ownerApproval =
                  data[
                          'ownerApprovalStatus']
                      ?.toString() ??
                  'pending';

              final adminApproval =
                  data[
                          'adminApprovalStatus']
                      ?.toString() ??
                  'pending';

              return Card(
                margin:
                    const EdgeInsets.only(
                  bottom: 18,
                ),
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(
                    18,
                  ),
                ),

                child: Padding(
                  padding:
                      const EdgeInsets.all(
                    18,
                  ),

                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,

                    children: [
                      // ==================================================
                      // HEADER
                      // ==================================================

                      Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration:
                                BoxDecoration(
                              color:
                                  primaryOrange
                                      .withValues(
                                alpha: 0.10,
                              ),
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                14,
                              ),
                            ),
                            child:
                                const Icon(
                              Icons
                                  .admin_panel_settings_outlined,
                              color:
                                  primaryOrange,
                            ),
                          ),

                          const SizedBox(
                            width: 12,
                          ),

                          const Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                  'Agent Verification',
                                  style:
                                      TextStyle(
                                    fontSize: 18,
                                    fontWeight:
                                        FontWeight
                                            .bold,
                                  ),
                                ),
                                SizedBox(
                                  height: 5,
                                ),
                                Text(
                                  'Awaiting admin review',
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.orange,
                                    fontSize: 12,
                                    fontWeight:
                                        FontWeight
                                            .w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(
                        height: 20,
                      ),

                      // ==================================================
                      // PROPERTY
                      // ==================================================

                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets
                                .all(14),
                        decoration:
                            BoxDecoration(
                          color:
                              const Color(
                            0xFFF5F5F5,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Property',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),

                            const SizedBox(
                              height: 8,
                            ),

                            // ============================================================
                            // PROPERTY TITLE
                            // ============================================================

                            FutureBuilder<DocumentSnapshot>(
                              future: FirebaseFirestore.instance
                                  .collection('properties')
                                  .doc(propertyId)
                                  .get(),
                              builder: (context, propertySnapshot) {
                                String propertyTitle = 'Property';

                                if (propertySnapshot.hasData &&
                                    propertySnapshot.data!.exists) {
                                  final propertyData =
                                      propertySnapshot.data!.data()
                                          as Map<String, dynamic>?;

                                  propertyTitle =
                                      propertyData?['title']?.toString().trim() ??
                                          'Property';

                                  if (propertyTitle.isEmpty) {
                                    propertyTitle = 'Property';
                                  }
                                }

                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      propertyTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),

                                    const SizedBox(height: 5),

                                    Text(
                                      'Property ID: $propertyId',
                                      style: const TextStyle(
                                        color: secondaryTextColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(
                        height: 16,
                      ),

                      // ==================================================
                      // OWNER
                      // ==================================================

                      const Text(
                        'Owner Information',
                        style: TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      Text(
                        'Name: $ownerName',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 5,
                      ),

                      Text(
                        'Phone: $ownerPhone',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 5,
                      ),

                      Text(
                        'Email: $ownerEmail',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                        ),
                      ),

                      const SizedBox(
                        height: 5,
                      ),

                      Text(
                        'Owner UID: $ownerUid',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                          fontSize: 11,
                        ),
                      ),

                      const SizedBox(
                        height: 16,
                      ),

                      // ==================================================
                      // AGENT
                      // ==================================================

                      const Text(
                        'Agent Information',
                        style: TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      Text(
                        'Agent UID: $agentId',
                        style:
                            const TextStyle(
                          color:
                              secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),

                      const SizedBox(
                        height: 18,
                      ),

                      // ==================================================
                      // APPROVAL STATUS
                      // ==================================================

                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets
                                .all(14),
                        decoration:
                            BoxDecoration(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            12,
                          ),
                          border:
                              Border.all(
                            color: Colors
                                .orange
                                .withValues(
                              alpha: 0.30,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons
                                      .check_circle_outline,
                                  color:
                                      Colors.green,
                                  size: 20,
                                ),
                                const SizedBox(
                                  width: 10,
                                ),
                                Expanded(
                                  child: Text(
                                    'Owner approval: '
                                    '${ownerApproval.toUpperCase()}',
                                    style:
                                        const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(
                              height: 10,
                            ),

                            Row(
                              children: [
                                const Icon(
                                  Icons
                                      .pending_outlined,
                                  color:
                                      Colors.orange,
                                  size: 20,
                                ),
                                const SizedBox(
                                  width: 10,
                                ),
                                Expanded(
                                  child: Text(
                                    'Admin approval: '
                                    '${adminApproval.toUpperCase()}',
                                    style:
                                        const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(
                        height: 22,
                      ),

                      const Divider(),

                      const SizedBox(
                        height: 14,
                      ),

                      // ==================================================
                      // ADMIN ACTIONS
                      // ==================================================

                      const Text(
                        'Admin decision',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              FontWeight.w600,
                        ),
                      ),

                      const SizedBox(
                        height: 12,
                      ),

                      Row(
                        children: [
                          Expanded(
                            child:
                                OutlinedButton(
                              onPressed: () {
                                _rejectRepresentation(
                                  context,
                                  document.id,
                                  data,
                                );
                              },
                              style:
                                  OutlinedButton
                                      .styleFrom(
                                foregroundColor:
                                    Colors.red,
                                side:
                                    const BorderSide(
                                  color:
                                      Colors.red,
                                ),
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  vertical:
                                      14,
                                ),
                              ),
                              child:
                                  const Text(
                                'Reject',
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(
                            width: 12,
                          ),

                          Expanded(
                            child:
                                ElevatedButton(
                              onPressed: () {
                                _approveRepresentation(
                                  context,
                                  document.id,
                                  data,
                                );
                              },
                              style:
                                  ElevatedButton
                                      .styleFrom(
                                backgroundColor:
                                    primaryOrange,
                                foregroundColor:
                                    Colors.white,
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  vertical:
                                      14,
                                ),
                              ),
                              child:
                                  const Text(
                                'Approve',
                                style:
                                    TextStyle(
                                  fontWeight:
                                      FontWeight
                                          .bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
// ============================================================
// MY LISTINGS
// ============================================================

class MyListingsScreen extends StatefulWidget {
  const MyListingsScreen({super.key});

  @override
  State<MyListingsScreen> createState() =>
      _MyListingsScreenState();
}

class _MyListingsScreenState
    extends State<MyListingsScreen> {
  bool isCheckingRole = true;
bool isLandlord = false;
bool isAgent = false;

  @override
  void initState() {
    super.initState();
    _checkLandlordRole();
  }

  Future<void> _checkLandlordRole() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    if (!mounted) return;

    setState(() {
      isCheckingRole = false;
      isLandlord = false;
      isAgent = false;
    });

    return;
  }

  try {
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final data = userDoc.data();
    final role = data?['role']?.toString().toLowerCase();

    if (!mounted) return;

    if (role == 'landlord' ||
    role == 'agent') {
  setState(() {
    isCheckingRole = false;
    isLandlord = role == 'landlord';
    isAgent = role == 'agent';
  });
} else {
      setState(() {
        isCheckingRole = false;
        isLandlord = false;
        isAgent = false;
      });

      _showAccessDenied();
    }
  } catch (e) {
    if (!mounted) return;

    setState(() {
      isCheckingRole = false;
      isLandlord = false;
      isAgent = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not verify your account type. Please try again.',
        ),
      ),
    );
  }
}

  void _showAccessDenied() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            icon: const Icon(
              Icons.lock_outline,
              color: primaryOrange,
              size: 42,
            ),
            title: const Text(
  'Property Provider Access',
),
content: const Text(
  'This section is available to landlord and agent accounts.',
),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);

                  if (mounted) {
                    Navigator.pop(context);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryOrange,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'Go Back',
                ),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isCheckingRole) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('My Listings'),
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: primaryOrange,
              ),
              SizedBox(height: 16),
              Text(
                'Checking your account...',
                style: TextStyle(
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!isLandlord && !isAgent) {
  return Scaffold(
    appBar: AppBar(
      title: const Text('My Listings'),
    ),
    body: const Center(
      child: Text(
        'Landlord or Agent access required.',
        style: TextStyle(
          color: secondaryTextColor,
          fontSize: 16,
        ),
      ),
    ),
  );
}

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('My Listings'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(25),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 70,
                  color: Colors.grey,
                ),
                const SizedBox(height: 15),
                const Text(
                  'Login required',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please login to view and manage your property listings.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: secondaryTextColor,
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AuthScreen(),
                      ),
                    );
                  },
                  child: const Text('Login'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Listings'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AddPropertyScreen(),
                ),
              );
            },
            icon: const Icon(Icons.add),
            tooltip: 'Add Property',
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
    .collection('properties')
    .where(
      isAgent ? 'managedById' : 'ownerId',
      isEqualTo: user.uid,
    )
    .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 60,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'Could not load your listings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please check your connection and try again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryTextColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final documents = [
            ...snapshot.data?.docs ?? [],
          ];

          documents.sort((a, b) {
            final aData = a.data();
            final bData = b.data();

            final aTime =
                (aData['submittedAt'] as Timestamp?)
                    ?.toDate();

            final bTime =
                (bData['submittedAt'] as Timestamp?)
                    ?.toDate();

            if (aTime == null && bTime == null) {
              return 0;
            }

            if (aTime == null) {
              return 1;
            }

            if (bTime == null) {
              return -1;
            }

            return bTime.compareTo(aTime);
          });

          if (documents.isEmpty) {
            return _emptyState(context);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: documents.length,
            itemBuilder: (context, index) {
              final document = documents[index];
              final data = document.data();

              final listing = LandlordListing(
  id: data['id']?.toString() ?? document.id,
  ownerId:
      data['ownerId']?.toString() ?? user.uid,
  managedById:
      data['managedById']?.toString() ?? user.uid,
  title: data['title']?.toString() ??
      'Untitled Property',
                location:
                    data['location']?.toString() ?? '',
                propertyType:
                    data['propertyType']?.toString() ??
                        'Apartment',
                rent:
                    (data['rent'] as num?)?.toInt() ?? 0,
                bedrooms:
                    (data['bedrooms'] as num?)?.toInt() ?? 0,
                bathrooms:
                    (data['bathrooms'] as num?)?.toInt() ?? 1,
                size:
                    (data['size'] as num?)?.toInt() ?? 0,
                availability:
                  data['availability']?.toString() ??
                      'Available now',

              availableFrom: data['availableFrom'] is Timestamp
                  ? (data['availableFrom'] as Timestamp).toDate()
                  : null,

              description:
                  data['description']?.toString() ?? '',
                amenities: List<String>.from(
                  data['amenities'] ?? [],
                ),
                submittedAt:
                    data['submittedAt'] is Timestamp
                        ? (data['submittedAt'] as Timestamp)
                            .toDate()
                        : DateTime.now(),
                photoPaths: List<String>.from(
                  data['photoPaths'] ?? [],
                ),
              );

                          final status =
                data['status']?.toString() ?? 'pending';
                debugPrint(
  'MY LISTING DEBUG: '
  'property=${listing.id}, '
  'status=$status, '
  'ownerId=${data['ownerId']}, '
  'managedById=${data['managedById']}, '
  'currentUser=${user.uid}',
);

            final rejectionReason =
                status == 'admin_rejected'
                    ? data['adminRejectionReason']
                            ?.toString() ??
                        ''
                    : data['rejectionReason']
                            ?.toString() ??
                        '';

            return _listingCard(
              context,
              listing,
              status,
              rejectionReason,
            );
            },
          );
        },
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(25),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.home_work_outlined,
              size: 75,
              color: Colors.grey,
            ),
            const SizedBox(height: 15),
            const Text(
              'No listings yet',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add your first property to start reaching tenants and manage your listings.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryTextColor,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const AddPropertyScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('Add Property'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListingPhoto(String path) {
    if (path.startsWith('http')) {
      return Image.network(
        path,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
        loadingBuilder: (
          context,
          child,
          loadingProgress,
        ) {
          if (loadingProgress == null) {
            return child;
          }

          return Container(
            color: Colors.grey.shade200,
            child: const Center(
              child: CircularProgressIndicator(
                color: primaryOrange,
              ),
            ),
          );
        },
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return Container(
            color: Colors.grey.shade200,
            child: const Icon(
              Icons.broken_image_outlined,
              size: 50,
              color: Colors.grey,
            ),
          );
        },
      );
    }

    return Image.file(
      File(path),
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return Container(
          color: Colors.grey.shade200,
          child: const Icon(
            Icons.broken_image_outlined,
            size: 50,
            color: Colors.grey,
          ),
        );
      },
    );
  }

  Color _availabilityColor(String availability) {
    switch (availability) {
      case 'Available now':
        return availableGreen;
      case 'Available this month':
        return Colors.orange;
      case 'Available next month':
        return Colors.blue;
      case 'Reserved':
        return Colors.amber.shade800;
      case 'Rented / Occupied':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _availabilityIcon(String availability) {
    switch (availability) {
      case 'Available now':
        return Icons.check_circle_outline;
      case 'Available this month':
        return Icons.event_available_outlined;
      case 'Available next month':
        return Icons.calendar_month_outlined;
      case 'Reserved':
        return Icons.lock_outline;
      case 'Rented / Occupied':
        return Icons.home_work_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Widget _listingCard(
    BuildContext context,
    LandlordListing listing,
    String status,
    String rejectionReason,
  ) {
    Color statusColor;
    Color statusBackground;
    String statusText;
    IconData statusIcon;

    if (status == 'approved') {
  statusColor = availableGreen;
  statusBackground = Colors.green.shade50;
  statusText = 'Approved';
  statusIcon = Icons.check_circle_outline;
} else if (status == 'admin_rejected') {
  statusColor = Colors.red.shade700;
  statusBackground = Colors.red.shade50;
  statusText = 'Rejected by RentalApp';
  statusIcon = Icons.cancel_outlined;
} else if (status == 'rejected') {
  statusColor = Colors.red.shade700;
  statusBackground = Colors.red.shade50;
  statusText = 'Rejected by Owner';
  statusIcon = Icons.cancel_outlined;
} else if (status == 'owner_approved') {
  statusColor = Colors.blue.shade700;
  statusBackground = Colors.blue.shade50;
  statusText = 'Pending RentalApp Verification';
  statusIcon = Icons.admin_panel_settings_outlined;
} else {
  statusColor = primaryOrange;
  statusBackground = Colors.orange.shade50;
  statusText = 'Waiting for Owner';
  statusIcon = Icons.hourglass_empty;
}
    final availabilityColor =
        _availabilityColor(listing.availability);

    final availabilityIcon =
        _availabilityIcon(listing.availability);

    return Card(
      margin: const EdgeInsets.only(bottom: 15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  LandlordPropertyManagementScreen(
                listing: listing,
                status: status,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
                        const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PropertyViewingScheduleScreen(
                        propertyId: listing.id,
                        propertyTitle: listing.title,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('Manage Viewing Schedule'),
              ),
            ),
            if (listing.photoPaths.isNotEmpty)
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          _PhotoFullScreenViewer(
                        photos: listing.photoPaths
                            .map(
                              (path) => XFile(path),
                            )
                            .toList(),
                        initialIndex: 0,
                        category: 'Property Photos',
                        mainPhotoPath:
                            listing.photoPaths.first,
                        onSetMainPhoto: (_) {},
                      ),
                    ),
                  );
                },
                child: SizedBox(
                  height: 190,
                  width: double.infinity,
                  child: Stack(
                    children: [
                      _buildListingPhoto(
                        listing.photoPaths.first,
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star,
                                color: Colors.white,
                                size: 15,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Main Photo',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius:
                                BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${listing.photoPaths.length} photo${listing.photoPaths.length == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight:
                                  FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Container(
                height: 150,
                width: double.infinity,
                color: Colors.grey.shade200,
                child: const Icon(
                  Icons.apartment,
                  size: 60,
                  color: Colors.grey,
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          listing.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding:
                            const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: statusBackground,
                          borderRadius:
                              BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Icon(
                              statusIcon,
                              size: 14,
                              color: statusColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              statusText,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 16,
                        color: secondaryTextColor,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          listing.location,
                          style: const TextStyle(
                            color:
                                secondaryTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

// PROPERTY TYPE
Row(
  children: [
    const Icon(
      Icons.home_work_outlined,
      size: 16,
      color: secondaryTextColor,
    ),
    const SizedBox(width: 5),
    Text(
      listing.propertyType,
      style: const TextStyle(
        color: secondaryTextColor,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  ],
),

const SizedBox(height: 10),

Text(
  'KSh ${listing.rent} / month',
                    style: const TextStyle(
                      color: primaryOrange,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: availabilityColor
                          .withOpacity(0.10),
                      borderRadius:
                          BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          availabilityIcon,
                          size: 16,
                          color: availabilityColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          listing.availability,
                          style: TextStyle(
                            color: availabilityColor,
                            fontSize: 12,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.bed_outlined,
                        size: 17,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        listing.bedrooms == 0
                            ? 'Bedsitter'
                            : '${listing.bedrooms} bed',
                      ),
                      const SizedBox(width: 15),
                      Icon(
                        Icons.bathtub_outlined,
                        size: 17,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${listing.bathrooms} bath',
                      ),
                      const SizedBox(width: 15),
                      if (listing.size > 0)
                        Text(
                          '${listing.size} sq ft',
                        ),
                    ],
                  ),
                              if ((status == 'rejected' ||
                    status == 'admin_rejected') &&
                rejectionReason.trim().isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin:
                          const EdgeInsets.only(top: 14),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius:
                            BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.red.shade100,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                color:
                                    Colors.red.shade700,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    Text(
                                      'Corrections Required',
                                      style: TextStyle(
                                        color: Colors.red
                                            .shade700,
                                        fontSize: 15,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    const Text(
                                      'Your listing needs some changes before it can be approved.',
                                      style: TextStyle(
                                        color:
                                            secondaryTextColor,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Admin feedback:',
                                      style: TextStyle(
                                        color: Colors.red
                                            .shade700,
                                        fontWeight:
                                            FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      rejectionReason,
                                      style: const TextStyle(
                                        color:
                                            secondaryTextColor,
                                        fontSize: 14,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        EditPropertyScreen(
                                      listing: listing,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(
                                Icons.edit_outlined,
                              ),
                              label: const Text(
                                'Make Corrections',
                              ),
                              style:
                                  ElevatedButton.styleFrom(
                                backgroundColor:
                                    primaryOrange,
                                foregroundColor:
                                    Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                                shape:
                                    RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Center(
                            child: Text(
                              'Update the required details and save your changes.',
                              textAlign:
                                  TextAlign.center,
                              style: TextStyle(
                                color:
                                    secondaryTextColor,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                LandlordPropertyManagementScreen(
                              listing: listing,
                              status: status,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.manage_accounts_outlined,
                      ),
                      label: const Text(
                        'Manage Property',
                      ),
                    ),
                  ),
                  if (listing.photoPaths.isNotEmpty)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: 10),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    _PhotoFullScreenViewer(
                                  photos: listing
                                      .photoPaths
                                      .map(
                                        (path) =>
                                            XFile(path),
                                      )
                                      .toList(),
                                  initialIndex: 0,
                                  category:
                                      'Property Photos',
                                  mainPhotoPath: listing
                                      .photoPaths.first,
                                  onSetMainPhoto: (_) {},
                                ),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.photo_library_outlined,
                          ),
                          label: Text(
                            'View Photos (${listing.photoPaths.length})',
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// ============================================================
// LANDLORD PROPERTY MANAGEMENT
// ============================================================

class LandlordPropertyManagementScreen
    extends StatefulWidget {
  final LandlordListing listing;
  final String status;

  const LandlordPropertyManagementScreen({
    super.key,
    required this.listing,
    required this.status,
  });

  @override
  State<LandlordPropertyManagementScreen> createState() =>
      _LandlordPropertyManagementScreenState();
}

class _LandlordPropertyManagementScreenState
    extends State<LandlordPropertyManagementScreen> {
  bool isCheckingRole = true;
bool isLandlord = false;
bool isAgent = false;

  LandlordListing get listing => widget.listing;
  String get status => widget.status;

  @override
  void initState() {
    super.initState();
    _checkLandlordRole();
  }

  Future<void> _checkLandlordRole() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
      });

      _showAccessDenied(
        'Please log in to access property management.',
      );

      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final data = userDoc.data();
      final role = data?['role']?.toString().toLowerCase();

      if (!mounted) return;

      if (role == 'landlord' || role == 'agent') {
  setState(() {
    isCheckingRole = false;
    isLandlord = role == 'landlord';
    isAgent = role == 'agent';
  });
} else {
  setState(() {
    isCheckingRole = false;
    isLandlord = false;
  });

  _showAccessDenied(
    'This section is available only to landlord and agent accounts.',
  );
}
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isCheckingRole = false;
        isLandlord = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not verify your account type. Please try again.',
          ),
        ),
      );
    }
  }

  void _showAccessDenied(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            icon: const Icon(
              Icons.lock_outline,
              color: primaryOrange,
              size: 42,
            ),
            title: const Text(
              'Property Provider Access',
            ),
            content: Text(message),
            actions: [
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);

                  if (mounted) {
                    Navigator.pop(context);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryOrange,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'Go Back',
                ),
              ),
            ],
          );
        },
      );
    });
  }

  Color get statusColor {
    if (status == 'approved') {
      return availableGreen;
    }

    if (status == 'rejected') {
      return Colors.red.shade700;
    }

    return primaryOrange;
  }

  String get statusText {
    if (status == 'approved') {
      return 'Approved';
    }

    if (status == 'rejected') {
      return 'Rejected';
    }

    return 'Pending verification';
  }

  Widget _buildPhoto(
    String path, {
    double height = 240,
  }) {
    if (path.startsWith('http')) {
      return Image.network(
        path,
        width: double.infinity,
        height: height,
        fit: BoxFit.cover,
        loadingBuilder: (
          context,
          child,
          loadingProgress,
        ) {
          if (loadingProgress == null) {
            return child;
          }

          return Container(
            height: height,
            color: Colors.grey.shade200,
            child: const Center(
              child: CircularProgressIndicator(
                color: primaryOrange,
              ),
            ),
          );
        },
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return Container(
            height: height,
            color: Colors.grey.shade200,
            child: const Icon(
              Icons.broken_image_outlined,
              size: 60,
              color: Colors.grey,
            ),
          );
        },
      );
    }

    return Image.file(
      File(path),
      width: double.infinity,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return Container(
          height: height,
          color: Colors.grey.shade200,
          child: const Icon(
            Icons.broken_image_outlined,
            size: 60,
            color: Colors.grey,
          ),
        );
      },
    );
  }

  void _openPhotos(BuildContext context) {
    if (listing.photoPaths.isEmpty) {
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhotoFullScreenViewer(
          photos: listing.photoPaths
              .map((path) => XFile(path))
              .toList(),
          initialIndex: 0,
          category: 'Property Photos',
          mainPhotoPath: listing.photoPaths.first,
          onSetMainPhoto: (_) {},
        ),
      ),
    );
  }

  Widget _actionButton({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onPressed,
    bool destructive = false,
  }) {
    final Color iconColor =
        destructive ? Colors.red.shade700 : primaryOrange;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: destructive
              ? Colors.red.shade100
              : Colors.grey.shade200,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: destructive
                        ? Colors.red.withOpacity(0.08)
                        : primaryOrange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    icon,
                    color: iconColor,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: destructive
                              ? Colors.red.shade700
                              : textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: secondaryTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailItem(
    IconData icon,
    String value,
    String label,
  ) {
    return Row(
      children: [
        Icon(
          icon,
          color: primaryOrange,
          size: 24,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: const TextStyle(
                  color: secondaryTextColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isCheckingRole) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Manage Property'),
        ),
        backgroundColor: const Color(0xFFFAFAFA),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: primaryOrange,
              ),
              SizedBox(height: 16),
              Text(
                'Checking your account...',
                style: TextStyle(
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    
    


    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Property'),
      ),
      backgroundColor: const Color(0xFFFAFAFA),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 35),
        children: [
          // ======================================================
          // PROPERTY PHOTO
          // ======================================================
          if (listing.photoPaths.isNotEmpty)
            GestureDetector(
              onTap: () => _openPhotos(context),
              child: SizedBox(
                height: 250,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildPhoto(listing.photoPaths.first),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color:
                              Colors.black.withOpacity(0.65),
                          borderRadius:
                              BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons
                                  .photo_library_outlined,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${listing.photoPaths.length} Photos',
                              style:
                                  const TextStyle(
                                color: Colors.white,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Container(
              height: 250,
              width: double.infinity,
              color: Colors.grey.shade200,
              child: const Icon(
                Icons.apartment,
                size: 90,
                color: Colors.grey,
              ),
            ),

          // ======================================================
          // PROPERTY HEADER
          // ======================================================
          Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              20,
              16,
              10,
            ),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  listing.title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 18,
                      color: secondaryTextColor,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        listing.location,
                        style: const TextStyle(
                          color: secondaryTextColor,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color:
                            statusColor.withOpacity(0.12),
                        borderRadius:
                            BorderRadius.circular(20),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'KSh ${listing.rent} / month',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: primaryOrange,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ======================================================
          // PROPERTY DETAILS
          // ======================================================
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: _detailItem(
                    Icons.home_work_outlined,
                    listing.propertyType,
                    'Property Type',
                  ),
                ),
                Expanded(
                  child: _detailItem(
                    Icons.bed_outlined,
                    listing.bedrooms == 0
                        ? 'Bedsitter'
                        : '${listing.bedrooms} Bedroom',
                    'Bedrooms',
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _detailItem(
                    Icons.bathtub_outlined,
                    '${listing.bathrooms}',
                    'Bathrooms',
                  ),
                ),
                Expanded(
                  child: _detailItem(
                    Icons.square_foot_outlined,
                    '${listing.size} sq ft',
                    'Size',
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ======================================================
          // AVAILABILITY
          // ======================================================
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.grey.shade200,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.event_available_outlined,
                    color: primaryOrange,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Availability',
                          style: TextStyle(
                            fontSize: 12,
                            color: secondaryTextColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          listing.availability,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ======================================================
          // AMENITIES
          // ======================================================
          if (listing.amenities.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16,
                0,
                16,
                16,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Amenities',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        listing.amenities.map(
                      (amenity) {
                        return Container(
                          padding:
                              const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Colors.grey.shade100,
                            borderRadius:
                                BorderRadius.circular(
                              20,
                            ),
                          ),
                          child: Text(
                            amenity,
                            style:
                                const TextStyle(
                              fontSize: 13,
                            ),
                          ),
                        );
                      },
                    ).toList(),
                  ),
                ],
              ),
            ),

          // ======================================================
          // DESCRIPTION
          // ======================================================
          if (listing.description
              .trim()
              .isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16,
                0,
                16,
                20,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Description',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    listing.description,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
              ),
            ),

          // ======================================================
          // ACTIONS
          // ======================================================
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child: Column(
              children: [
                _actionButton(
                  context: context,
                  icon: Icons.photo_library_outlined,
                  title: 'View All Photos',
                  subtitle:
                      'View all uploaded property photos',
                  onPressed: () {
                    _openPhotos(context);
                  },
                ),

                // ==================================================
                // EDIT PROPERTY
                // ==================================================
                _actionButton(
                  context: context,
                  icon: Icons.edit_outlined,
                  title: 'Edit Property',
                  subtitle:
                      'Update your property details',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            EditPropertyScreen(
                          listing: listing,
                        ),
                      ),
                    );
                  },
                ),

                // ==================================================
                // CHANGE AVAILABILITY
                // ==================================================
                _actionButton(
                  context: context,
                  icon:
                      Icons.event_available_outlined,
                  title: 'Change Availability',
                  subtitle:
                      'Current: ${listing.availability}',
                  onPressed: () async {
                    String selectedAvailability = listing.availability;
                    DateTime? selectedAvailableFrom = listing.availableFrom;
                    final result =
                        await showModalBottomSheet<
                            String>(
                      context: context,
                      shape:
                          const RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      builder: (sheetContext) {
                        return StatefulBuilder(
                          builder: (
                            context,
                            setModalState,
                          ) {
                            return SafeArea(
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  20,
                                  20,
                                  20,
                                  20 + MediaQuery.of(context).viewInsets.bottom,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                     const Text(
                                    'Change Availability',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight:
                                          FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(
                                      height: 8),
                                  const Text(
                                    'Update the current rental status of this property.',
                                    style: TextStyle(
                                      color:
                                          secondaryTextColor,
                                    ),
                                  ),
                                  const SizedBox(
                                      height: 16),
                                  ...[
                                    'Available now',
                                    'Available this month',
                                    'Available next month',
                                    'Reserved',
                                    'Rented / Occupied',
                                  ].map(
                                    (availability) {
                                      return RadioListTile<
                                          String>(
                                        value:
                                            availability,
                                        groupValue:
                                            selectedAvailability,
                                        title: Text(
                                            availability),
                                        activeColor:
                                            primaryOrange,
                                        onChanged:
                                            (value) {
                                          if (value ==
                                              null) {
                                            return;
                                          }

                                          setModalState(() {
                                              selectedAvailability = value;

                                              if (value != 'Available this month' &&
                                                  value != 'Available next month') {
                                                selectedAvailableFrom = null;
                                              }
                                            });
                                        },
                                      );
                                    },
                                  ),
                                if (selectedAvailability ==
                                                'Available this month' ||
                                            selectedAvailability ==
                                                'Available next month') ...[
                                          const SizedBox(height: 12),
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              final pickedDate = await showDatePicker(
                                                context: context,
                                                initialDate: selectedAvailableFrom ??
                                                    DateTime.now().add(
                                                      const Duration(days: 1),
                                                    ),
                                                firstDate: DateTime.now(),
                                                lastDate: DateTime.now().add(
                                                  const Duration(days: 365),
                                                ),
                                              );

                                              if (pickedDate != null) {
                                                setModalState(() {
                                                  selectedAvailableFrom = pickedDate;
                                                });
                                              }
                                            },
                                            icon: const Icon(Icons.calendar_month),
                                            label: Text(
                                              selectedAvailableFrom == null
                                                  ? 'Choose expected availability date'
                                                  : 'Expected date: ${selectedAvailableFrom!.day}/'
                                                      '${selectedAvailableFrom!.month}/'
                                                      '${selectedAvailableFrom!.year}',
                                            ),
                                          ),
                                        ],
                                  const SizedBox(
                                      height: 12),
                                  SizedBox(
                                    width:
                                        double.infinity,
                                    child:
                                        ElevatedButton(
                                      onPressed: () {
                                        Navigator.pop(
                                          sheetContext,
                                          selectedAvailability,
                                        );
                                      },
                                      style:
                                          ElevatedButton
                                              .styleFrom(
                                        backgroundColor:
                                            primaryOrange,
                                        foregroundColor:
                                            Colors.white,
                                        padding:
                                            const EdgeInsets
                                                .symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child:
                                          const Text(
                                        'Save Availability',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                      height: 8),
                                ],
                               ),
                              ),
                             ),
                            );
                          },
                        );
                      },
                    );

                    if (result == null) {
                            return;
                          }

                    try {
                      await FirebaseFirestore.instance
                          .collection('properties')
                          .doc(listing.id)
                          .update({
                        'availability': result,
                        'availableFrom':
                            (result == 'Available this month' ||
                                    result == 'Available next month')
                                ? (selectedAvailableFrom != null
                                    ? Timestamp.fromDate(
                                        selectedAvailableFrom!,
                                      )
                                    : null)
                                : null,
                      });

                      if (!context.mounted) {
                        return;
                      }

                      ScaffoldMessenger.of(context)
                          .showSnackBar(
                        SnackBar(
                          content: Text(
                            'Availability updated to $result',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!context.mounted) {
                        return;
                      }

                      ScaffoldMessenger.of(context)
                          .showSnackBar(
                        SnackBar(
                          content: Text(
                            'Failed to update availability: $e',
                          ),
                        ),
                      );
                    }
                  },
                ),

                // ==================================================
                // PROPERTY DETAILS
                // ==================================================
                _actionButton(
                  context: context,
                  icon: Icons.info_outline,
                  title: 'Property Details',
                  subtitle:
                      'View complete property information',
                  onPressed: () {
                    showModalBottomSheet(
                      context: context,
                      shape:
                          const RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                      ),
                      builder: (sheetContext) {
                        return Padding(
                          padding:
                              const EdgeInsets.all(20),
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              const Text(
                                'Property Details',
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                              const SizedBox(
                                  height: 16),
                              Text(
                                'Property ID: ${listing.id}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Property Type: ${listing.propertyType}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Location: ${listing.location}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Rent: KSh ${listing.rent}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Bedrooms: ${listing.bedrooms == 0 ? 'Bedsitter' : listing.bedrooms}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Bathrooms: ${listing.bathrooms}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Size: ${listing.size} sq ft',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Availability: ${listing.availability}',
                              ),
                              const SizedBox(
                                  height: 8),
                              Text(
                                'Status: $statusText',
                              ),
                              const SizedBox(
                                  height: 20),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(
                                    sheetContext,
                                  );
                                },
                                style:
                                    ElevatedButton
                                        .styleFrom(
                                  backgroundColor:
                                      primaryOrange,
                                  foregroundColor:
                                      Colors.white,
                                ),
                                child:
                                    const Text(
                                  'Close',
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),

                // ==================================================
                // DELETE PROPERTY
                // ==================================================
                _actionButton(
                  context: context,
                  icon: Icons.delete_outline,
                  title: 'Delete Property',
                  subtitle:
                      'Permanently remove this listing',
                  destructive: true,
                  onPressed: () async {
                    final user =
                        FirebaseAuth.instance.currentUser;

                    if (user == null) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Please login before deleting a property.',
                          ),
                        ),
                      );
                      return;
                    }

                    final canDelete = user.uid == listing.ownerId ||
    user.uid == listing.managedById;

if (!canDelete) {
  ScaffoldMessenger.of(context)
      .showSnackBar(
    const SnackBar(
      content: Text(
        'You do not have permission to delete this property.',
      ),
    ),
  );
  return;
}

                    final confirmed =
                        await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) {
                        return AlertDialog(
                          title: const Text(
                            'Delete Property?',
                          ),
                          content: Text(
                            'Are you sure you want to permanently delete '
                            '"${listing.title}"?\n\n'
                            'This will remove the property listing and its uploaded photos.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                Navigator.pop(
                                  dialogContext,
                                  false,
                                );
                              },
                              child: const Text(
                                'Cancel',
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                Navigator.pop(
                                  dialogContext,
                                  true,
                                );
                              },
                              style:
                                  ElevatedButton
                                      .styleFrom(
                                backgroundColor:
                                    Colors.red,
                                foregroundColor:
                                    Colors.white,
                              ),
                              child: const Text(
                                'Delete',
                              ),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmed != true) {
                      return;
                    }

                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) {
                        return const AlertDialog(
                          content: Row(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(width: 20),
                              Expanded(
                                child: Text(
                                  'Deleting property...',
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );

                    try {
                      // Delete Firestore property.
                      await FirebaseFirestore.instance
                          .collection('properties')
                          .doc(listing.id)
                          .delete();

                      // Delete all uploaded photos.
                      final propertyStorageRef =
                          FirebaseStorage.instance
                              .ref()
                              .child('properties')
                              .child(listing.id);

                      final storageResult =
                          await propertyStorageRef
                              .listAll();

                      for (final item
                          in storageResult.items) {
                        await item.delete();
                      }

                      for (final prefix
                          in storageResult.prefixes) {
                        final categoryResult =
                            await prefix.listAll();

                        for (final item
                            in categoryResult.items) {
                          await item.delete();
                        }
                      }

                      if (!context.mounted) return;

                      Navigator.pop(context);
                      Navigator.pop(context, true);
                    } catch (e) {
                      if (!context.mounted) return;

                      Navigator.pop(context);

                      ScaffoldMessenger.of(context)
                          .showSnackBar(
                        SnackBar(
                          content: Text(
                            'Failed to delete property: $e',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EditPropertyScreen extends StatefulWidget {
  final LandlordListing listing;

  // True when the landlord is correcting a rejected listing.
  final bool isCorrectionMode;

  const EditPropertyScreen({
    super.key,
    required this.listing,
    this.isCorrectionMode = false,
  });

  @override
  State<EditPropertyScreen> createState() =>
      _EditPropertyScreenState();
}

class _EditPropertyScreenState
    extends State<EditPropertyScreen> {
  late final TextEditingController titleController;
  late final TextEditingController rentController;
  late final TextEditingController sizeController;
  late final TextEditingController descriptionController;

  late String selectedPropertyType;
  late String selectedPropertySetting;
  late String selectedBedrooms;
  late String selectedBathrooms;
  late String selectedAvailability;

  late String? selectedCounty;
  late String? selectedCity;
  late String? selectedArea;

  late Set<String> selectedAmenities;

  bool isSaving = false;

  final List<String> propertyTypeOptions = [
  'Apartment',
  'Standalone House',
  'Maisonette',
  'Townhouse',
  'Villa',
  'Gated Community',
  'Serviced Apartment',
  'Studio / Bedsitter',
  'Other',
];
final List<String> propertySettingOptions = [
  'Apartment Block',
  'Standalone / Own Compound',
  'Gated Community',
  'Shared Compound',
  'Other',
];

  final List<String> bedroomOptions = [
    'Bedsitter',
    '1',
    '2',
    '3',
    '4+',
  ];

  final List<String> bathroomOptions = [
    '1',
    '2',
    '3',
    '4+',
  ];

  final List<String> availabilityOptions = [
    'Available now',
    'Available this month',
    'Available next month',
  ];

  final List<String> amenityOptions = [
    'Parking',
    'Security',
    'Water',
    'Lift',
    'Internet',
    'Generator',
    'Swimming Pool',
    'CCTV',
    'Balcony',
    'Furnished',
  ];

  List<String> get countyOptions {
    return kenyaLocations
        .map((location) => location.county)
        .toSet()
        .toList();
  }

  List<String> get cityOptions {
    if (selectedCounty == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county == selectedCounty,
        )
        .map((location) => location.city)
        .toSet()
        .toList();
  }

  List<String> get areaOptions {
    if (selectedCounty == null ||
        selectedCity == null) {
      return [];
    }

    return kenyaLocations
        .where(
          (location) =>
              location.county == selectedCounty &&
              location.city == selectedCity,
        )
        .map((location) => location.area)
        .toSet()
        .toList();
  }

  @override
  void initState() {
    super.initState();

    titleController = TextEditingController(
      text: widget.listing.title,
    );

    rentController = TextEditingController(
      text: widget.listing.rent.toString(),
    );

    sizeController = TextEditingController(
      text: widget.listing.size > 0
          ? widget.listing.size.toString()
          : '',
    );

    descriptionController = TextEditingController(
      text: widget.listing.description,
    );

    selectedPropertyType =
        widget.listing.propertyType;

    if (!propertyTypeOptions.contains(
      selectedPropertyType,
    )) {
      selectedPropertyType =
          propertyTypeOptions.first;
    }
    selectedPropertySetting =
    widget.listing.propertySetting;

        if (!propertySettingOptions.contains(
          selectedPropertySetting,
        )) {
          selectedPropertySetting =
              propertySettingOptions.first;
        }

    if (widget.listing.bedrooms == 0) {
      selectedBedrooms = 'Bedsitter';
    } else if (widget.listing.bedrooms >= 4) {
      selectedBedrooms = '4+';
    } else {
      selectedBedrooms =
          widget.listing.bedrooms.toString();
    }

    if (widget.listing.bathrooms >= 4) {
      selectedBathrooms = '4+';
    } else if (widget.listing.bathrooms >= 1) {
      selectedBathrooms =
          widget.listing.bathrooms.toString();
    } else {
      selectedBathrooms = '1';
    }

    selectedAvailability =
        availabilityOptions.contains(
      widget.listing.availability,
    )
            ? widget.listing.availability
            : availabilityOptions.first;

    selectedAmenities =
        Set<String>.from(widget.listing.amenities);

    // Try to recover the structured location
    // from the property's saved county/city/area.
    //
    // The listing model currently stores the complete
    // location as "$area, $city", so we first recover
    // city and area from that value.
    selectedCounty = null;
    selectedCity = null;
    selectedArea = null;

    final parts = widget.listing.location
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.length >= 2) {
      final possibleArea = parts[0];
      final possibleCity = parts[1];

      final matchingLocations = kenyaLocations.where(
        (location) =>
            location.city == possibleCity &&
            location.area == possibleArea,
      );

      if (matchingLocations.isNotEmpty) {
        selectedCounty =
            matchingLocations.first.county;
        selectedCity = possibleCity;
        selectedArea = possibleArea;
      }
    }
  }

  @override
  void dispose() {
    titleController.dispose();
    rentController.dispose();
    sizeController.dispose();
    descriptionController.dispose();

    super.dispose();
    
  }

  Future<void> saveChanges() async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Please login to edit this property.',
        ),
      ),
    );
    return;
  }

  final canEdit = user.uid == widget.listing.ownerId ||
      user.uid == widget.listing.managedById;

  if (!canEdit) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'You do not have permission to edit this property.',
        ),
      ),
    );
    return;
  }

  if (titleController.text.trim().isEmpty ||
      selectedCounty == null ||
      selectedCity == null ||
      selectedArea == null ||
      rentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter property title, location and rent.',
          ),
        ),
      );
      return;
    }

    final rent = int.tryParse(
      rentController.text.replaceAll(',', '').trim(),
    );

    if (rent == null || rent <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter a valid monthly rent.',
          ),
        ),
      );
      return;
    }

    final size = int.tryParse(
          sizeController.text.trim(),
        ) ??
        0;

    int bedrooms = 0;

    if (selectedBedrooms == '1') {
      bedrooms = 1;
    } else if (selectedBedrooms == '2') {
      bedrooms = 2;
    } else if (selectedBedrooms == '3') {
      bedrooms = 3;
    } else if (selectedBedrooms == '4+') {
      bedrooms = 4;
    }

    int bathrooms =
        int.tryParse(selectedBathrooms) ?? 1;

    if (selectedBathrooms == '4+') {
      bathrooms = 4;
    }

    setState(() {
      isSaving = true;
    });

    try {
      await FirebaseFirestore.instance
    .collection('properties')
    .doc(widget.listing.id)
    .update({
  'title': titleController.text.trim(),
  'propertyType': selectedPropertyType,
  'propertySetting': selectedPropertySetting,
  'county': selectedCounty,
  'city': selectedCity,
  'area': selectedArea,
  'location': '$selectedArea, $selectedCity',
  'rent': rent,
  'bedrooms': bedrooms,
  'bathrooms': bathrooms,
  'size': size,
  'availability': selectedAvailability,
  'description': descriptionController.text.trim(),
  'amenities': selectedAmenities.toList(),

  // Rejected listing is being corrected and sent
  // back to the admin for verification.
  if (widget.isCorrectionMode) ...{
    'status': 'pending',
    'verified': false,
    'rejectionReason': '',
  },
});

      if (!mounted) return;

      setState(() {
        isSaving = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Property updated successfully.',
          ),
        ),
      );

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isSaving = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update property.\n$e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Widget _buildLocationOption({
    required IconData icon,
    required String title,
    required String value,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    final hasValue =
        value != 'Select county' &&
        value != 'Select city or town' &&
        value != 'Select area or estate';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 13,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0xFFFFF8F2)
                : const Color(0xFFF5F5F5),
            borderRadius:
                BorderRadius.circular(13),
            border: Border.all(
              color: enabled
                  ? primaryOrange.withOpacity(0.12)
                  : Colors.grey.withOpacity(0.12),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: enabled
                    ? primaryOrange
                    : Colors.grey,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 11,
                        color: enabled
                            ? secondaryTextColor
                            : Colors.grey,
                        fontWeight:
                            FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: hasValue
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: enabled
                            ? (hasValue
                                ? textColor
                                : secondaryTextColor)
                            : Colors.grey,
                      ),
                      overflow:
                          TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: enabled
                    ? secondaryTextColor
                    : Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLocationPicker({
    required String title,
    required List<String> items,
    required String? selectedValue,
    required ValueChanged<String> onSelected,
  }) {
    final searchController =
        TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (
            sheetContext,
            setSheetState,
          ) {
            final searchText =
                searchController.text
                    .trim()
                    .toLowerCase();

            final filteredItems =
                items.where((item) {
              return item
                  .toLowerCase()
                  .contains(searchText);
            }).toList();

            return Container(
              height:
                  MediaQuery.of(sheetContext)
                          .size
                          .height *
                      0.72,
              decoration:
                  const BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),

                  Container(
                    width: 42,
                    height: 5,
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.grey.shade300,
                      borderRadius:
                          BorderRadius.circular(
                        10,
                      ),
                    ),
                  ),

                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(
                      20,
                      18,
                      20,
                      10,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons
                              .location_on_outlined,
                          color: primaryOrange,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style:
                                const TextStyle(
                              fontSize: 19,
                              fontWeight:
                                  FontWeight.bold,
                              color: textColor,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              Navigator.pop(
                            sheetContext,
                          ),
                          icon: const Icon(
                            Icons.close_rounded,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 20,
                    ),
                    child: TextField(
                      controller:
                          searchController,
                      onChanged: (_) {
                        setSheetState(() {});
                      },
                      decoration:
                          InputDecoration(
                        hintText:
                            'Search $title...',
                        prefixIcon:
                            const Icon(
                          Icons.search_rounded,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFF7F7F7,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  Expanded(
                    child:
                        filteredItems.isEmpty
                            ? const Center(
                                child: Text(
                                  'No locations found',
                                  style: TextStyle(
                                    color:
                                        secondaryTextColor,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                itemCount:
                                    filteredItems
                                        .length,
                                itemBuilder:
                                    (
                                  context,
                                  index,
                                ) {
                                  final item =
                                      filteredItems[
                                          index];

                                  final isSelected =
                                      item ==
                                          selectedValue;

                                  return ListTile(
                                    title:
                                        Text(item),
                                    leading:
                                        const Icon(
                                      Icons
                                          .location_on_outlined,
                                      color:
                                          primaryOrange,
                                    ),
                                    trailing:
                                        isSelected
                                            ? const Icon(
                                                Icons
                                                    .check_circle,
                                                color:
                                                    primaryOrange,
                                              )
                                            : const Icon(
                                                Icons
                                                    .chevron_right_rounded,
                                                color:
                                                    Colors.grey,
                                              ),
                                    onTap: () {
                                      onSelected(
                                        item,
                                      );
                                      Navigator.pop(
                                        sheetContext,
                                      );
                                    },
                                  );
                                },
                              ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailDropdown({
    required String label,
    required IconData icon,
    required String value,
    required List<String> items,
    required String Function(String) displayValue,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: secondaryTextColor,
          ),
        ),
        const SizedBox(height: 7),
        DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(
            prefixIcon: Icon(
              icon,
              color: primaryOrange,
            ),
            filled: true,
            fillColor:
                const Color(0xFFFFF8F2),
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder:
                OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(14),
              borderSide: BorderSide(
                color: primaryOrange
                    .withOpacity(0.10),
              ),
            ),
          ),
          items: items
              .map(
                (item) =>
                    DropdownMenuItem<String>(
                  value: item,
                  child: Text(
                    displayValue(item),
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          const Color(0xFFFAFAFA),
      appBar: AppBar(
        title: const Text(
          'Edit Property',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: Stack(
        children: [
          ListView(
            padding:
                const EdgeInsets.fromLTRB(
              16,
              12,
              16,
              30,
            ),
            children: [
              Container(
                padding:
                    const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withOpacity(0.04),
                      blurRadius: 14,
                      offset:
                          const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Property Details',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight:
                            FontWeight.bold,
                        color: textColor,
                      ),
                    ),

                    const SizedBox(height: 20),

                    const Text(
                      'Property title',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                        color:
                            secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    TextField(
                      controller:
                          titleController,
                      decoration:
                          InputDecoration(
                        prefixIcon:
                            const Icon(
                          Icons.home_outlined,
                          color:
                              primaryOrange,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                        enabledBorder:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide(
                            color:
                                primaryOrange
                                    .withOpacity(
                              0.10,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    const Text(
                      'Property type',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                        color:
                            secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    DropdownButtonFormField<String>(
                      initialValue:
                          selectedPropertyType,
                      decoration:
                          InputDecoration(
                        prefixIcon:
                            const Icon(
                          Icons
                              .apartment_outlined,
                          color:
                              primaryOrange,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                      items:
                          propertyTypeOptions
                              .map(
                                (
                                  type,
                                ) =>
                                    DropdownMenuItem<
                                        String>(
                                  value: type,
                                  child:
                                      Text(type),
                                ),
                              )
                              .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            selectedPropertyType =
                                value;
                          });
                        }
                      },
                    ),

                    const SizedBox(height: 18),

                    // PROPERTY SETTING
                    const Text(
                      'Property setting',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    DropdownButtonFormField<String>(
                      initialValue: selectedPropertySetting,
                      isExpanded: true,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          Icons.location_city_outlined,
                          color: primaryOrange,
                        ),
                        filled: true,
                        fillColor: const Color(0xFFFFF8F2),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: primaryOrange.withOpacity(0.10),
                          ),
                        ),
                      ),
                      items: propertySettingOptions.map(
                        (setting) => DropdownMenuItem<String>(
                          value: setting,
                          child: Text(
                            setting,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            selectedPropertySetting = value;
                          });
                        }
                      },
                    ),

                    const SizedBox(height: 18),

                    _buildLocationOption(
                      icon: Icons
                          .map_outlined,
                      title: 'County',
                      value:
                          selectedCounty ??
                              'Select county',
                      enabled: true,
                      onTap: () {
                        _showLocationPicker(
                          title:
                              'Select County',
                          items:
                              countyOptions,
                          selectedValue:
                              selectedCounty,
                          onSelected: (value) {
                            setState(() {
                              selectedCounty =
                                  value;
                              selectedCity =
                                  null;
                              selectedArea =
                                  null;
                            });
                          },
                        );
                      },
                    ),

                    const SizedBox(height: 8),

                    _buildLocationOption(
                      icon: Icons
                          .location_city_outlined,
                      title: 'City / Town',
                      value:
                          selectedCity ??
                              'Select city or town',
                      enabled:
                          selectedCounty != null,
                      onTap:
                          selectedCounty ==
                                  null
                              ? null
                              : () {
                                  _showLocationPicker(
                                    title:
                                        'Select City / Town',
                                    items:
                                        cityOptions,
                                    selectedValue:
                                        selectedCity,
                                    onSelected:
                                        (
                                      value,
                                    ) {
                                      setState(
                                        () {
                                          selectedCity =
                                              value;
                                          selectedArea =
                                              null;
                                        },
                                      );
                                    },
                                  );
                                },
                    ),

                    const SizedBox(height: 8),

                    _buildLocationOption(
                      icon:
                          Icons.place_outlined,
                      title:
                          'Area / Estate',
                      value:
                          selectedArea ??
                              'Select area or estate',
                      enabled:
                          selectedCity != null,
                      onTap:
                          selectedCity ==
                                  null
                              ? null
                              : () {
                                  _showLocationPicker(
                                    title:
                                        'Select Area / Estate',
                                    items:
                                        areaOptions,
                                    selectedValue:
                                        selectedArea,
                                    onSelected:
                                        (
                                      value,
                                    ) {
                                      setState(
                                        () {
                                          selectedArea =
                                              value;
                                        },
                                      );
                                    },
                                  );
                                },
                    ),

                    const SizedBox(height: 18),

                    const Text(
                      'Monthly rent',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                        color:
                            secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    TextField(
                      controller:
                          rentController,
                      keyboardType:
                          TextInputType.number,
                      decoration:
                          InputDecoration(
                        prefixText: 'KSh ',
                        prefixStyle:
                            const TextStyle(
                          fontWeight:
                              FontWeight.bold,
                          color:
                              primaryOrange,
                        ),
                        prefixIcon:
                            const Icon(
                          Icons
                              .payments_outlined,
                          color:
                              primaryOrange,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    Row(
                      children: [
                        Expanded(
                          child:
                              _buildDetailDropdown(
                            label:
                                'Bedrooms',
                            icon: Icons
                                .bed_outlined,
                            value:
                                selectedBedrooms,
                            items:
                                bedroomOptions,
                            displayValue:
                                (value) {
                              if (value ==
                                  'Bedsitter') {
                                return 'Bedsitter';
                              }

                              return '$value Bedroom${value == '1' ? '' : 's'}';
                            },
                            onChanged:
                                (value) {
                              if (value !=
                                  null) {
                                setState(() {
                                  selectedBedrooms =
                                      value;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(
                            width: 12),
                        Expanded(
                          child:
                              _buildDetailDropdown(
                            label:
                                'Bathrooms',
                            icon: Icons
                                .bathtub_outlined,
                            value:
                                selectedBathrooms,
                            items:
                                bathroomOptions,
                            displayValue:
                                (value) =>
                                    '$value Bathroom${value == '1' ? '' : 's'}',
                            onChanged:
                                (value) {
                              if (value !=
                                  null) {
                                setState(() {
                                  selectedBathrooms =
                                      value;
                                });
                              }
                            },
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    const Text(
                      'Property size',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                        color:
                            secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    TextField(
                      controller:
                          sizeController,
                      keyboardType:
                          TextInputType.number,
                      decoration:
                          InputDecoration(
                        suffixText:
                            'sq ft',
                        prefixIcon:
                            const Icon(
                          Icons
                              .square_foot_outlined,
                          color:
                              primaryOrange,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    const Text(
                      'Availability',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                        color:
                            secondaryTextColor,
                      ),
                    ),

                    const SizedBox(height: 7),

                    DropdownButtonFormField<String>(
                      initialValue:
                          selectedAvailability,
                      decoration:
                          InputDecoration(
                        prefixIcon:
                            const Icon(
                          Icons
                              .event_available_outlined,
                          color:
                              primaryOrange,
                        ),
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                      items:
                          availabilityOptions
                              .map(
                                (
                                  value,
                                ) =>
                                    DropdownMenuItem<
                                        String>(
                                  value: value,
                                  child: Text(
                                    value,
                                  ),
                                ),
                              )
                              .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            selectedAvailability =
                                value;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              Container(
                padding:
                    const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withOpacity(0.04),
                      blurRadius: 14,
                      offset:
                          const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Amenities',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight:
                            FontWeight.bold,
                        color: textColor,
                      ),
                    ),

                    const SizedBox(height: 16),

                    Wrap(
                      spacing: 9,
                      runSpacing: 9,
                      children:
                          amenityOptions.map(
                        (amenity) {
                          final selected =
                              selectedAmenities
                                  .contains(
                            amenity,
                          );

                          return FilterChip(
                            label:
                                Text(amenity),
                            selected:
                                selected,
                            avatar: Icon(
                              selected
                                  ? Icons.check
                                  : Icons.add,
                              size: 17,
                              color: selected
                                  ? primaryOrange
                                  : secondaryTextColor,
                            ),
                            selectedColor:
                                primaryOrange
                                    .withOpacity(
                              0.14,
                            ),
                            backgroundColor:
                                const Color(
                              0xFFF7F7F7,
                            ),
                            onSelected:
                                (value) {
                              setState(() {
                                if (value) {
                                  selectedAmenities
                                      .add(
                                    amenity,
                                  );
                                } else {
                                  selectedAmenities
                                      .remove(
                                    amenity,
                                  );
                                }
                              });
                            },
                          );
                        },
                      ).toList(),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              Container(
                padding:
                    const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black
                          .withOpacity(0.04),
                      blurRadius: 14,
                      offset:
                          const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Property Description',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight:
                            FontWeight.bold,
                        color: textColor,
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller:
                          descriptionController,
                      maxLines: 6,
                      decoration:
                          InputDecoration(
                        hintText:
                            'Describe the property...',
                        filled: true,
                        fillColor:
                            const Color(
                          0xFFFFF8F2,
                        ),
                        border:
                            OutlineInputBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            14,
                          ),
                          borderSide:
                              BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed:
                      isSaving
                          ? null
                          : saveChanges,
                  icon: isSaving
                      ? const SizedBox(
                          width: 21,
                          height: 21,
                          child:
                              CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color:
                                Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.save_outlined,
                        ),
                  label: Text(
                    isSaving
                        ? 'Saving Changes...'
                        : 'Save Changes',
                    style:
                        const TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        primaryOrange,
                    foregroundColor:
                        Colors.white,
                    disabledBackgroundColor:
                        Colors.grey,
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(
                        16,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              const Center(
                child: Text(
                  'Your existing photos will not be changed.',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        secondaryTextColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PHOTO FULL SCREEN VIEWER
// ============================================================

class _PhotoFullScreenViewer extends StatefulWidget {
  final List<XFile> photos;
  final int initialIndex;
  final String category;
  final String? mainPhotoPath;
  final Function(String) onSetMainPhoto;

  const _PhotoFullScreenViewer({
    required this.photos,
    required this.initialIndex,
    required this.category,
    required this.mainPhotoPath,
    required this.onSetMainPhoto,
  });

  @override
  State<_PhotoFullScreenViewer> createState() =>
      _PhotoFullScreenViewerState();
}

class _PhotoFullScreenViewerState
    extends State<_PhotoFullScreenViewer> {
  late PageController pageController;
  late int currentIndex;

  @override
  void initState() {
    super.initState();

    currentIndex = widget.initialIndex;

    pageController = PageController(
      initialPage: widget.initialIndex,
    );
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  bool isNetworkPhoto(String path) {
    return path.startsWith('http');
  }

  Widget buildPhoto(XFile photo) {
    final path = photo.path;

    if (isNetworkPhoto(path)) {
      return Image.network(
        path,
        fit: BoxFit.contain,
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 70,
            ),
          );
        },
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return const Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Colors.white70,
            size: 70,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.category),
        ),
        body: const Center(
          child: Text('No photos available.'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${widget.category} • ${currentIndex + 1}/${widget.photos.length}',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: pageController,
              itemCount: widget.photos.length,
              onPageChanged: (index) {
                setState(() {
                  currentIndex = index;
                });
              },
              itemBuilder: (context, index) {
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: buildPhoto(
                      widget.photos[index],
                    ),
                  ),
                );
              },
            ),
          ),

          Container(
            height: 90,
            padding: const EdgeInsets.symmetric(
              vertical: 10,
              horizontal: 8,
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.photos.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final selected =
                    currentIndex == index;

                return GestureDetector(
                  onTap: () {
                    pageController.animateToPage(
                      index,
                      duration: const Duration(
                        milliseconds: 250,
                      ),
                      curve: Curves.easeInOut,
                    );
                  },
                  child: Container(
                    width: 75,
                    decoration: BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? primaryOrange
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(6),
                      child: buildPhoto(
                        widget.photos[index],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// TENANT PHOTO GALLERY
// ============================================================

class _TenantPhotoGallery extends StatefulWidget {
  final List<String> photoPaths;

  const _TenantPhotoGallery({
    required this.photoPaths,
  });

  @override
  State<_TenantPhotoGallery> createState() =>
      _TenantPhotoGalleryState();
}

class _TenantPhotoGalleryState
    extends State<_TenantPhotoGallery> {
  late PageController pageController;
  int currentIndex = 0;

  @override
  void initState() {
    super.initState();
    pageController = PageController();
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  // ============================================================
  // OPEN FULL SCREEN
  // ============================================================

  void openFullScreen(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _TenantFullScreenGallery(
          photoPaths: widget.photoPaths,
          initialIndex: index,
        ),
      ),
    );
  }

  // ============================================================
  // PLACEHOLDER FOR MISSING IMAGE
  // ============================================================

  Widget missingImage() {
    return Container(
      width: double.infinity,
      color: Colors.grey.shade200,
      child: const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 70,
          color: Colors.grey,
        ),
      ),
    );
  }

  // ============================================================
  // BUILD PHOTO SAFELY
  // ============================================================

  Widget buildPhoto(
    String path, {
    BoxFit fit = BoxFit.cover,
  }) {
    // ----------------------------------------------------------
    // FIREBASE STORAGE / INTERNET IMAGE
    // ----------------------------------------------------------

    if (path.startsWith('http://') ||
        path.startsWith('https://')) {
      return Image.network(
        path,
        width: double.infinity,
        fit: fit,
        loadingBuilder: (
          context,
          child,
          loadingProgress,
        ) {
          if (loadingProgress == null) {
            return child;
          }

          return const Center(
            child: CircularProgressIndicator(
              color: primaryOrange,
            ),
          );
        },
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return missingImage();
        },
      );
    }

    // ----------------------------------------------------------
    // LOCAL FILE
    //
    // IMPORTANT:
    // image_picker creates temporary cache files.
    // Android can delete those files later.
    // Never try to load a file that no longer exists.
    // ----------------------------------------------------------

    final file = File(path);

    if (!file.existsSync()) {
      return missingImage();
    }

    return Image.file(
      file,
      width: double.infinity,
      fit: fit,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return missingImage();
      },
    );
  }

  // ============================================================
  // MAIN GALLERY
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // No photos
    if (widget.photoPaths.isEmpty) {
      return Container(
        height: 250,
        width: double.infinity,
        color: Colors.grey.shade200,
        child: const Center(
          child: Icon(
            Icons.apartment,
            size: 90,
            color: Colors.grey,
          ),
        ),
      );
    }

    return Column(
      children: [
        // ========================================================
        // MAIN PHOTO
        // ========================================================

        SizedBox(
          height: 250,
          width: double.infinity,
          child: Stack(
            children: [
              PageView.builder(
                controller: pageController,
                itemCount: widget.photoPaths.length,
                onPageChanged: (index) {
                  if (!mounted) return;

                  setState(() {
                    currentIndex = index;
                  });
                },
                itemBuilder: (context, index) {
                  return GestureDetector(
                    onTap: () {
                      openFullScreen(index);
                    },
                    child: buildPhoto(
                      widget.photoPaths[index],
                    ),
                  );
                },
              ),

              // ==================================================
              // PHOTO COUNTER
              // ==================================================

              Positioned(
                right: 12,
                bottom: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius:
                        BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${currentIndex + 1}/${widget.photoPaths.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // ========================================================
        // THUMBNAILS
        // ========================================================

        SizedBox(
          height: 70,
          child: ListView.separated(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 12,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: widget.photoPaths.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final selected =
                  currentIndex == index;

              return GestureDetector(
                onTap: () {
                  pageController.animateToPage(
                    index,
                    duration:
                        const Duration(
                      milliseconds: 250,
                    ),
                    curve: Curves.easeInOut,
                  );
                },
                child: Container(
                  width: 75,
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? primaryOrange
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(7),
                    child: buildPhoto(
                      widget.photoPaths[index],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
// ============================================================
// TENANT FULL SCREEN GALLERY
// ============================================================

class _TenantFullScreenGallery
    extends StatefulWidget {
  final List<String> photoPaths;
  final int initialIndex;

  const _TenantFullScreenGallery({
    required this.photoPaths,
    required this.initialIndex,
  });

  @override
  State<_TenantFullScreenGallery> createState() =>
      _TenantFullScreenGalleryState();
}

class _TenantFullScreenGalleryState
    extends State<_TenantFullScreenGallery> {
  late PageController pageController;
  late int currentIndex;

  @override
  void initState() {
    super.initState();

    currentIndex = widget.initialIndex;

    pageController = PageController(
      initialPage: widget.initialIndex,
    );
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  Widget buildPhoto(String path) {
    if (path.startsWith('http')) {
      return Image.network(
        path,
        fit: BoxFit.contain,
        errorBuilder: (
          context,
          error,
          stackTrace,
        ) {
          return const Center(
            child: Icon(
              Icons.broken_image,
              size: 70,
              color: Colors.white70,
            ),
          );
        },
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.contain,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return const Center(
          child: Icon(
            Icons.broken_image,
            size: 70,
            color: Colors.white70,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${currentIndex + 1}/${widget.photoPaths.length}',
        ),
      ),
      body: PageView.builder(
        controller: pageController,
        itemCount: widget.photoPaths.length,
        onPageChanged: (index) {
          setState(() {
            currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: buildPhoto(
                widget.photoPaths[index],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// ADMIN DASHBOARD
// ============================================================

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
      ),
      body: StreamBuilder<
          QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('properties')
            .orderBy(
              'submittedAt',
              descending: true,
            )
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                  'Could not load properties.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final documents =
              snapshot.data?.docs ?? [];

          int pendingCount = 0;
          int approvedCount = 0;
          int rejectedCount = 0;

          for (final document in documents) {
            final status =
                document.data()['status']?.toString() ??
                    'pending';

            if (status == 'pending') {
              pendingCount++;
            } else if (status == 'approved') {
              approvedCount++;
            } else if (status == 'rejected') {
              rejectedCount++;
            }
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _statusCard(
                      title: 'Pending',
                      count: pendingCount,
                      icon: Icons.pending_actions,
                      color: primaryOrange,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _statusCard(
                      title: 'Approved',
                      count: approvedCount,
                      icon:
                          Icons.check_circle_outline,
                      color: availableGreen,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _statusCard(
                      title: 'Rejected',
                      count: rejectedCount,
                      icon: Icons.cancel_outlined,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 25),

              const Text(
                'All Properties',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 12),

              if (documents.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(30),
                  child: Center(
                    child: Text(
                      'No properties submitted yet.',
                    ),
                  ),
                ),

              ...documents.map(
                (document) {
                  final data = document.data();

                  return _propertyCard(
                    context,
                    document.id,
                    data,
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _statusCard({
    required String title,
    required int count,
    required IconData icon,
    required Color color,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 16,
          horizontal: 8,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: color,
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _propertyCard(
    BuildContext context,
    String documentId,
    Map<String, dynamic> data,
  ) {
    final title =
        data['title']?.toString() ??
            'Untitled Property';

    final location =
        data['location']?.toString() ?? '';

    final rent =
        (data['rent'] as num?)?.toInt() ?? 0;

    final bedrooms =
        (data['bedrooms'] as num?)?.toInt() ?? 0;

    final bathrooms =
        (data['bathrooms'] as num?)?.toInt() ?? 0;

    final status =
        data['status']?.toString() ?? 'pending';

    final photoPaths = List<String>.from(
      data['photoPaths'] ?? [],
    );

    Color statusColor = primaryOrange;
    String statusText = 'Pending';

    if (status == 'approved') {
      statusColor = availableGreen;
      statusText = 'Approved';
    } else if (status == 'rejected') {
      statusColor = Colors.red;
      statusText = 'Rejected';
    }

    return Card(
      margin: const EdgeInsets.only(
        bottom: 14,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          if (photoPaths.isNotEmpty)
            SizedBox(
              height: 180,
              width: double.infinity,
              child: Image.network(
                photoPaths.first,
                fit: BoxFit.cover,
                loadingBuilder: (
                  context,
                  child,
                  loadingProgress,
                ) {
                  if (loadingProgress == null) {
                    return child;
                  }

                  return Container(
                    color: Colors.grey.shade200,
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: primaryOrange,
                      ),
                    ),
                  );
                },
                errorBuilder: (
                  context,
                  error,
                  stackTrace,
                ) {
                  return Container(
                    color: Colors.grey.shade200,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      size: 50,
                      color: Colors.grey,
                    ),
                  );
                },
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(15),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(
                          0.10,
                        ),
                        borderRadius:
                            BorderRadius.circular(8),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 7),

                Row(
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: secondaryTextColor,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        location,
                        style: const TextStyle(
                          color: secondaryTextColor,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                Text(
                  'KSh $rent / month',
                  style: const TextStyle(
                    color: primaryOrange,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  bedrooms == 0
                      ? 'Bedsitter • $bathrooms bath'
                      : '$bedrooms bedroom'
                          '${bedrooms == 1 ? '' : 's'} • '
                          '$bathrooms bath',
                ),

                const SizedBox(height: 12),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _showPropertyActions(
                        context,
                        documentId,
                        title,
                        status,
                      );
                    },
                    icon: const Icon(
                      Icons.manage_accounts_outlined,
                    ),
                    label: const Text(
                      'Manage Property',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showPropertyActions(
    BuildContext context,
    String documentId,
    String title,
    String status,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Current status: ${status.toUpperCase()}',
                  style: const TextStyle(
                    color: secondaryTextColor,
                  ),
                ),

                const SizedBox(height: 20),

                if (status != 'approved')
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);

                        await _updateStatus(
                          context,
                          documentId,
                          'approved',
                        );
                      },
                      icon: const Icon(
                        Icons.check_circle,
                      ),
                      label: const Text(
                        'Approve Property',
                      ),
                    ),
                  ),

                if (status != 'rejected')
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);

                        await _updateStatus(
                          context,
                          documentId,
                          'rejected',
                        );
                      },
                      icon: const Icon(
                        Icons.cancel_outlined,
                      ),
                      label: const Text(
                        'Reject Property',
                      ),
                    ),
                  ),

                if (status != 'pending')
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);

                        await _updateStatus(
                          context,
                          documentId,
                          'pending',
                        );
                      },
                      icon: const Icon(
                        Icons.pending_actions,
                      ),
                      label: const Text(
                        'Move Back to Pending',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _updateStatus(
    BuildContext context,
    String documentId,
    String status,
  ) async {
    String? rejectionReason;

    if (status == 'rejected') {
      rejectionReason = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          String reason = '';

          return AlertDialog(
            title: const Text('Reject Property'),
            content: TextField(
              maxLines: 4,
              onChanged: (value) {
                reason = value;
              },
              decoration: const InputDecoration(
                labelText: 'Reason for rejection',
                hintText:
                    'Example: Photos are unclear. Please upload clearer images.',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final trimmedReason =
                      reason.trim();

                  if (trimmedReason.isEmpty) {
                    return;
                  }

                  Navigator.of(dialogContext).pop(
                    trimmedReason,
                  );
                },
                child: const Text('Reject'),
              ),
            ],
          );
        },
      );

      if (rejectionReason == null ||
          rejectionReason.trim().isEmpty) {
        return;
      }
    }

    try {
      await FirebaseFirestore.instance
          .collection('properties')
          .doc(documentId)
          .update({
        'status': status,
        'verified': status == 'approved',
        'rejectionReason':
            status == 'rejected'
                ? rejectionReason
                : '',
      });

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'approved'
                ? 'Property approved successfully.'
                : status == 'rejected'
                    ? 'Property rejected with reason.'
                    : 'Property moved back to pending.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update property.\n$e',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}
class PropertyViewingScheduleScreen extends StatefulWidget {
  final String propertyId;
  final String propertyTitle;

  const PropertyViewingScheduleScreen({
    super.key,
    required this.propertyId,
    required this.propertyTitle,
  });

  @override
  State<PropertyViewingScheduleScreen> createState() =>
      _PropertyViewingScheduleScreenState();
}

class _PropertyViewingScheduleScreenState
    extends State<PropertyViewingScheduleScreen> {
  bool isLoading = true;
  bool isSaving = false;
  bool hasAccess = false;

  final List<String> dayKeys = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];

  final List<String> dayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  final Map<String, Map<String, dynamic>> schedule = {};

  @override
  void initState() {
    super.initState();

    for (final day in dayKeys) {
      schedule[day] = {
        'enabled': false,
        'start': '9:00 AM',
        'end': '5:00 PM',
      };
    }

    _loadSchedule();
  }

  Future<void> _loadSchedule() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() => isLoading = false);
      }
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final role = userDoc.data()?['role']
          ?.toString()
          .trim()
          .toLowerCase();

      final propertyDoc = await FirebaseFirestore.instance
          .collection('properties')
          .doc(widget.propertyId)
          .get();

      if (!propertyDoc.exists) {
        if (mounted) {
          setState(() => isLoading = false);
        }
        return;
      }

      final property = propertyDoc.data()!;

      final ownerId = property['ownerId']?.toString() ?? '';
      final managedById =
          property['managedById']?.toString() ?? '';

      final isAuthorizedLandlord =
          role == 'landlord' && ownerId == user.uid;

      final isAuthorizedAgent =
          role == 'agent' && managedById == user.uid;

      if (!isAuthorizedLandlord && !isAuthorizedAgent) {
        if (mounted) {
          setState(() => isLoading = false);
        }
        return;
      }

      final savedSchedule = property['viewingSchedule'];

      if (savedSchedule is Map) {
        for (final day in dayKeys) {
          final savedDay = savedSchedule[day];

          if (savedDay is Map) {
            schedule[day] = {
              'enabled': savedDay['enabled'] == true,
              'start': savedDay['start']?.toString() ??
                  '9:00 AM',
              'end': savedDay['end']?.toString() ??
                  '5:00 PM',
            };
          }
        }
      }

      if (!mounted) return;

      setState(() {
        hasAccess = true;
        isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() => isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not load the viewing schedule. Please try again.',
          ),
        ),
      );
    }
  }

  Future<void> _chooseTime(
    String day,
    String field,
  ) async {
    final currentValue = schedule[day]![field] as String;

    final initialTime = _parseTime(currentValue);

    final picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: field == 'start'
          ? 'Viewing start time'
          : 'Viewing end time',
    );

    if (picked == null || !mounted) return;

    setState(() {
      schedule[day]![field] = picked.format(context);
    });
  }

  TimeOfDay _parseTime(String value) {
    try {
      final parts = value.split(' ');
      final timeParts = parts[0].split(':');

      int hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);

      if (parts.length > 1) {
        if (parts[1].toUpperCase() == 'PM' && hour != 12) {
          hour += 12;
        } else if (parts[1].toUpperCase() == 'AM' &&
            hour == 12) {
          hour = 0;
        }
      }

      return TimeOfDay(hour: hour, minute: minute);
    } catch (_) {
      return const TimeOfDay(hour: 9, minute: 0);
    }
  }

  Future<void> _saveSchedule() async {
    if (!hasAccess || isSaving) return;

    for (final day in dayKeys) {
      final daySchedule = schedule[day]!;

      if (daySchedule['enabled'] != true) continue;

      final start = _parseTime(daySchedule['start'] as String);
      final end = _parseTime(daySchedule['end'] as String);

      final startMinutes = start.hour * 60 + start.minute;
      final endMinutes = end.hour * 60 + end.minute;

      if (endMinutes <= startMinutes) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${dayNames[dayKeys.indexOf(day)]}: end time must be later than start time.',
            ),
          ),
        );
        return;
      }
    }

    setState(() => isSaving = true);

    try {
      await FirebaseFirestore.instance
          .collection('properties')
          .doc(widget.propertyId)
          .update({
        'viewingSchedule': schedule,
        'viewingScheduleUpdatedAt': FieldValue.serverTimestamp(),
        'viewingScheduleUpdatedBy':
            FirebaseAuth.instance.currentUser?.uid ?? '',
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Viewing schedule saved successfully.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save the schedule. Please try again.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isSaving = false);
      }
    }
  }

  Widget _timeButton(
    String day,
    String field,
    String label,
  ) {
    return Expanded(
      child: OutlinedButton(
        onPressed: () => _chooseTime(day, field),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: secondaryTextColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              schedule[day]![field] as String,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Viewing Schedule'),
      ),
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: primaryOrange,
              ),
            )
          : !hasAccess
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'You are not authorized to manage this property’s viewing schedule.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text(
                            widget.propertyTitle,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Choose the days and hours when tenants can request property viewings. All days are initially unavailable until you enable them.',
                            style: TextStyle(
                              color: secondaryTextColor,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 18),
                          for (int i = 0; i < dayKeys.length; i++)
                            Card(
                              margin: const EdgeInsets.only(
                                bottom: 10,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    SwitchListTile(
                                      contentPadding:
                                          EdgeInsets.zero,
                                      title: Text(
                                        dayNames[i],
                                        style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold,
                                        ),
                                      ),
                                      subtitle: Text(
                                        schedule[dayKeys[i]]![
                                                    'enabled'] ==
                                                true
                                            ? 'Available for viewings'
                                            : 'Unavailable',
                                      ),
                                      value: schedule[dayKeys[i]]![
                                              'enabled'] ==
                                          true,
                                       activeColor: primaryOrange,
                                      onChanged: (enabled) {
                                        setState(() {
                                          schedule[dayKeys[i]]![
                                              'enabled'] = enabled;
                                        });
                                      },
                                    ),
                                    if (schedule[dayKeys[i]]![
                                            'enabled'] ==
                                        true) ...[
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          _timeButton(
                                            dayKeys[i],
                                            'start',
                                            'Starts',
                                          ),
                                          const SizedBox(width: 10),
                                          _timeButton(
                                            dayKeys[i],
                                            'end',
                                            'Ends',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: isSaving
                                ? null
                                : _saveSchedule,
                            icon: isSaving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(
                              isSaving
                                  ? 'Saving...'
                                  : 'Save Viewing Schedule',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryOrange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                vertical: 15,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}