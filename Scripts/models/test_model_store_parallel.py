"""Actual multi-process model publication/residency regression, no Core ML assets needed."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO=Path(__file__).resolve().parents[2]


class ModelStoreParallelTests(unittest.TestCase):
    def test_resident_weights_survive_other_process_and_are_reclaimed_after_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            driver=root/'Driver.swift'
            driver.write_text('''
import Foundation
import Darwin
@main struct Driver {
    static func main() throws {
        let args=CommandLine.arguments
        let store=NativeCoreMLModelStore(root:URL(fileURLWithPath:args[1]),runtimeCache:URL(fileURLWithPath:args[1]+"-runtime"))
        let url=try store.modelURL(for:URL(fileURLWithPath:args[2]))
        print(url.path); fflush(stdout)
        if args.count>3 { _=readLine() }
        guard try Data(contentsOf:url.appendingPathComponent("weight.bin")) == Data(args[2].utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        withExtendedLifetime(store) {}
    }
}
''')
            binary=root/'model-store'
            subprocess.run(['xcrun','swiftc','-O','-parse-as-library',
                str(REPO/'Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLModelStore.swift'),
                str(driver),'-o',str(binary)],check=True,capture_output=True,text=True)
            sources=[]
            for version in ['one','two','three']:
                source=root/version/'OCR.mlmodelc'
                source.mkdir(parents=True)
                (source/'model.mil').write_text(version)
                (source/'weight.bin').write_bytes(str(source).encode())
                sources.append(source)
            cache=root/'stable'
            first=subprocess.Popen([str(binary),str(cache),str(sources[0]),'hold'],
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                resident=Path(first.stdout.readline().strip())
                self.assertTrue((resident/'weight.bin').exists())
                subprocess.run([str(binary),str(cache),str(sources[1])],check=True,capture_output=True,text=True)
                self.assertTrue((resident/'weight.bin').exists(), 'Second process deleted first process model weights')
                first.communicate('\n',timeout=10)
                self.assertEqual(first.returncode,0)
                subprocess.run([str(binary),str(cache),str(sources[2])],check=True,capture_output=True,text=True)
                self.assertFalse(resident.exists(), 'Unleased obsolete model was not reclaimed')
                # Concurrent publication of identical content must converge on
                # one durable directory and both processes must read weights.
                children=[subprocess.Popen([str(binary),str(root/'concurrent'),str(sources[0]),'hold'],
                          stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)]
                try:
                    paths=[p.stdout.readline().strip() for p in children]
                    self.assertTrue(paths[0])
                    self.assertEqual(paths[0],paths[1])
                    for p in children:
                        p.communicate('\n',timeout=10)
                        self.assertEqual(p.returncode,0)
                finally:
                    for p in children:
                        if p.poll() is None:p.kill();p.wait()
            finally:
                if first.poll() is None:first.kill();first.wait()


if __name__=='__main__':
    unittest.main()
