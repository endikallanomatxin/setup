# My development setup

To replicate my development setup in Ubuntu 24.04+:

- clone this repository:

    ```sh
    sudo apt install git
    git clone https://github.com/endikallanomatxin/setup
    cd setup
    ```

- and run:

    ```sh
    bash setup.sh
    ```

After running the setup script, restart the computer to see all the changes applied.


After this, you might also want to:

- Login into github

    ```sh
    sudo apt install gh
    gh auth login
    ```

- Configure github copilot in neovim. Type `:Copilot`.

