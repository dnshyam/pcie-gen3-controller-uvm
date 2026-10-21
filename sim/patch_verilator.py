import re

p = "/home/shyam/.venv_pcie/lib/python3.12/site-packages/cocotb/share/lib/verilator/verilator.cpp"
try:
    with open(p, "r") as f:
        text = f.read()

    pattern = r"do \{\s+// We must evaluate whole design.*?top->eval_end_step\(\);"
    replacement = """#if VERILATOR_VERSION_INTEGER >= 5036000
        do {
            do {
                top->eval_step();
                VerilatedVpi::clearEvalNeeded();
                VerilatedVpi::doInertialPuts();
                settle_value_callbacks();
            } while (VerilatedVpi::evalNeeded());
            VerilatedVpi::callCbs(cbReadWriteSynch);
            VerilatedVpi::doInertialPuts();
            settle_value_callbacks();
        } while (VerilatedVpi::evalNeeded());
        top->eval_end_step();
#else
        top->eval();
        settle_value_callbacks();
        VerilatedVpi::callCbs(cbReadWriteSynch);
        settle_value_callbacks();
#endif"""

    new_text = re.sub(pattern, replacement, text, flags=re.DOTALL)
    if new_text != text:
        with open(p, "w") as f:
            f.write(new_text)
        print("Patched verilator.cpp successfully!")
    else:
        print("Pattern did not match")
except Exception as e:
    print(f"Error: {e}")
