async function main() {
  const vaultAddress = '0xB8419BC3bd9042834d098432Db0DD47aa55e7aAc';
  const strategyAddress = '0x929CDA5fEbC0e3CE8C64664847a20D3A208dD45c';

  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');
  const vault = Vault.attach(vaultAddress);

  await vault.initialize(strategyAddress);
  console.log('Vault initialized');
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
