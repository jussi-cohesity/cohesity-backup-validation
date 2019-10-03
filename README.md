# Cohesity backup validation PowerShell example

This is an example powershell for simple parallel and serial backup validation testing. 

With this example you can easily run testing for single VM or even against very complex application topology. All VMs are automatically cloned and then user-defined tests are applied against each VM. When tests are done all clones are automatically removed and summary of test results are shown.

# Prerequisites

* [PowerShell](https://aka.ms/getps6)
* [Cohesity PowerShell Module](https://cohesity.github.io/cohesity-powershell-module/#/)
* [VMware PowerCLI](https://www.powershellgallery.com/packages/VMware.PowerCLI/)
* [InvokeBuild](https://www.powershellgallery.com/packages/InvokeBuild/)


# Installation

Content of this folder can be downloaded to computer with network connectivity Cohesity and vCenter.

## Configuration

Configuration contains three files: environment.json, config.json and identity xml files for authentication.

### environment.json

This file contains both Cohesity and VMware vCenter server information. Cohesity part contains Cohesity cluster name and credential files. VMware part contains vCenter address, credentials and resource pool used for testing.

```PowerShell
{
        "cohesityCluster": cohesity-01",
        "cohesityCred": "./cohesity_cred.xml",
        "vmwareServer": "vcenter-01",
        "vmwareResourcePool": "Resources",
        "vmwareCred": "./vmware_cred.xml"
}
```

### config.json

This file contains information about virtual machines being tested and tests run per virtual machine

```PowerShell
{
    "virtualMachines": [
        {
            "name": "Win2012",
            "guestOS": "Windows",
            "backupJobName": "VM_Job",
            "guestCred": "./guestvm_cred.xml",
            "VmNamePrefix": "0210-",
            "testIp": "10.99.1.222",
            "testNetwork": "VM Network",
            "testSubnet": "24",
            "testGateway": "10.99.1.1",
            "tasks": ["Ping","getWindowsServicesStatus"]
        },
        {
            "name": "mysql",
            "guestOS": "Linux",
            "linuxNetDev": "eth0",
            "backupJobName": "VM_Job",
            "guestCred": "./guestvm_cred_linux.xml",
            "VmNamePrefix": "0310-",
            "testIp": "10.99.1.223",
            "testNetwork": "VM Network",
            "testSubnet": "24",
            "testGateway": "10.99.1.1",
            "tasks": ["Ping","MySQLStatus"]
        }
    ]
}
```

### identity xml files

Identity XML files are not included here. They can be created with [createCredentials.ps1](https://github.com/jussi-cohesity/cohesity-backup-validation/blob/master/createCredentials.ps1) file. This example script creates only one identity file for guests, but if you need multiple create additional by using same commands.

Note: Secure XML files can only be decrypted by the user account that created them.

## Usage

After creation of environment.json, config.json and required identity xml files you can run cohesity-backup-validation.ps1 to automate testing.


# Notes
This is not an official Cohesity repository. Cohesity Inc. is not affiliated with the posted examples in any way.

```
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

You can contact me via email (firstname AT cohesity.com)
